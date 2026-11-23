-- Vault view counters.
-- Totals and daily dedupe live in unexposed app_private.
-- Clients send only a SHA-256 hex of (anonymous localStorage id + page key +
-- America/New_York date). No IPs, emails, user ids or raw visitor ids are stored.
-- Applied to project yzfhecjvuorvvsrfoktt as migration vault_view_counts.

create table app_private.vault_view_counts (
  page_key text primary key,
  view_count bigint not null default 0 check (view_count >= 0),
  updated_at timestamptz not null default now(),
  constraint vault_view_counts_page_key_chk check (
    page_key = 'site' or page_key ~ '^card:[0-9]{3}$'
  )
);
comment on table app_private.vault_view_counts is
  'Public page/card view totals. Written only by app_private.record_vault_view.';

create table app_private.vault_view_hits (
  page_key text not null,
  visitor_day_hash text not null,
  first_seen_at timestamptz not null default now(),
  primary key (page_key, visitor_day_hash),
  constraint vault_view_hits_hash_chk check (visitor_day_hash ~ '^[0-9a-f]{64}$'),
  constraint vault_view_hits_page_key_chk check (
    page_key = 'site' or page_key ~ '^card:[0-9]{3}$'
  )
);
comment on table app_private.vault_view_hits is
  'Daily dedupe of views. Stores only a client-made SHA-256 hex (visitor id + page + date). No IPs or personal data.';

alter table app_private.vault_view_counts enable row level security;
alter table app_private.vault_view_hits enable row level security;
revoke all on table app_private.vault_view_counts from public, anon, authenticated;
revoke all on table app_private.vault_view_hits from public, anon, authenticated;

create or replace function app_private.record_vault_view(p_page_key text, p_visitor_day_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := btrim(coalesce(p_page_key, ''));
  v_hash text := lower(btrim(coalesce(p_visitor_day_hash, '')));
  v_count bigint;
  v_new boolean := false;
begin
  if v_key <> 'site' and v_key !~ '^card:[0-9]{3}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_page');
  end if;
  if v_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_hash');
  end if;

  insert into app_private.vault_view_hits (page_key, visitor_day_hash)
  values (v_key, v_hash)
  on conflict (page_key, visitor_day_hash) do nothing;
  if found then
    v_new := true;
    insert into app_private.vault_view_counts (page_key, view_count, updated_at)
    values (v_key, 1, now())
    on conflict (page_key) do update
      set view_count = app_private.vault_view_counts.view_count + 1,
          updated_at = now();
  end if;

  select c.view_count into v_count
    from app_private.vault_view_counts c
   where c.page_key = v_key;
  return jsonb_build_object(
    'ok', true,
    'page_key', v_key,
    'count', coalesce(v_count, 0),
    'counted', v_new
  );
end;
$$;

create or replace function app_private.vault_view_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'site', coalesce((select view_count from app_private.vault_view_counts where page_key = 'site'), 0),
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('card_no', substr(page_key, 6), 'count', view_count)
                       order by view_count desc, page_key)
        from app_private.vault_view_counts
       where page_key like 'card:%'
    ), '[]'::jsonb)
  );
$$;

revoke all on function app_private.record_vault_view(text, text) from public, anon, authenticated;
revoke all on function app_private.vault_view_stats() from public, anon, authenticated;
grant execute on function app_private.record_vault_view(text, text), app_private.vault_view_stats() to anon, authenticated;

create or replace function public.record_vault_view(page_key text, visitor_day_hash text)
returns jsonb
language sql
set search_path = ''
as $$ select app_private.record_vault_view(page_key, visitor_day_hash); $$;

create or replace function public.vault_view_stats()
returns jsonb
language sql
stable
set search_path = ''
as $$ select app_private.vault_view_stats(); $$;

revoke all on function public.record_vault_view(text, text), public.vault_view_stats() from public, anon, authenticated;
grant execute on function public.record_vault_view(text, text), public.vault_view_stats() to anon, authenticated;
