-- Vault v2 · 1/4 · Collector profiles and handles (additive only)
-- Handles: 3–20 chars, letters/numbers/underscore, unique ignoring case,
-- underscores and look-alike digits. Reserved, impersonation and profanity
-- terms are blocked server-side in app_private.handle_problem().

create table if not exists app_private.reserved_handles (
  term  text primary key,
  kind  text not null check (kind in ('exact', 'contains', 'regex')),
  reason text not null check (reason in ('reserved', 'impersonation', 'profanity'))
);
alter table app_private.reserved_handles enable row level security;
revoke all on app_private.reserved_handles from public, anon, authenticated;

insert into app_private.reserved_handles (term, kind, reason) values
  -- reserved words / site paths
  ('admin','contains','reserved'), ('administrator','exact','reserved'), ('root','exact','reserved'),
  ('moderator','contains','reserved'), ('mod','exact','reserved'), ('mods','exact','reserved'),
  ('support','contains','reserved'), ('help','exact','reserved'), ('helpdesk','exact','reserved'),
  ('staff','contains','reserved'), ('team','exact','reserved'), ('official','contains','reserved'),
  ('system','exact','reserved'), ('owner','exact','reserved'), ('founder','exact','reserved'),
  ('founders','exact','reserved'), ('vault','exact','reserved'), ('thevault','exact','reserved'),
  ('null','exact','reserved'), ('undefined','exact','reserved'), ('anonymous','exact','reserved'),
  ('unclaimed','exact','reserved'), ('claimed','exact','reserved'), ('store','exact','reserved'),
  ('shop','exact','reserved'), ('claim','exact','reserved'), ('wall','exact','reserved'),
  ('videos','exact','reserved'), ('api','exact','reserved'), ('www','exact','reserved'),
  ('mail','exact','reserved'), ('email','exact','reserved'), ('security','exact','reserved'),
  ('verified','contains','reserved'), ('chief','exact','reserved'), ('me','exact','reserved'),
  -- brand / people impersonation
  ('vaultedshelf','contains','impersonation'), ('vaultshelf','contains','impersonation'),
  ('vaultedshel','contains','impersonation'),
  ('ebay','contains','impersonation'), ('supabase','contains','impersonation'),
  ('funko','contains','impersonation'), ('sanrio','contains','impersonation'),
  ('^(the|real|its|im|iam|official|not)?ace(bot|ai|official|team|real|vault|vs|shelf|ofvaults?)?$','regex','impersonation'),
  -- profanity / slurs (matched after leet + underscore folding)
  ('fuck','contains','profanity'), ('fuk','contains','profanity'), ('shit','contains','profanity'),
  ('bitch','contains','profanity'), ('cunt','contains','profanity'), ('nigg','contains','profanity'),
  ('nigga','contains','profanity'), ('faggot','contains','profanity'), ('fag','exact','profanity'),
  ('rape','exact','profanity'), ('rapist','contains','profanity'), ('nazi','contains','profanity'),
  ('hitler','contains','profanity'), ('porn','contains','profanity'), ('pussy','contains','profanity'),
  ('whore','contains','profanity'), ('slut','contains','profanity'), ('kkk','contains','profanity'),
  ('retard','contains','profanity'), ('chink','contains','profanity'), ('spic','exact','profanity'),
  ('kike','contains','profanity'), ('twat','contains','profanity'), ('wank','exact','profanity'), ('wanker','contains','profanity'),
  ('cock','exact','profanity'), ('cocksucker','contains','profanity'), ('dick','exact','profanity'), ('dickhead','contains','profanity'),
  ('asshole','contains','profanity'), ('bastard','contains','profanity'), ('motherf','contains','profanity'),
  ('pedo','exact','profanity'), ('pedophile','contains','profanity'), ('molest','contains','profanity'), ('tranny','contains','profanity')
on conflict (term) do nothing;

-- Folded key used for uniqueness and term checks: lower, underscores removed,
-- common look-alikes folded (0→o 1→i 3→e 4→a 5→s 7→t 8→b 9→g).
create or replace function app_private.handle_key(p_handle text)
returns text language sql immutable set search_path = ''
as $$
  select translate(replace(lower(coalesce(p_handle, '')), '_', ''), '013457896', 'oieastbgg');
$$;

create or replace function app_private.handle_problem(p_handle text)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  v_key text := app_private.handle_key(p_handle);
  v_low text := lower(coalesce(p_handle, ''));
  v_reason text;
begin
  if p_handle is null or p_handle !~ '^[A-Za-z0-9_]{3,20}$' then
    return 'format';
  end if;
  if p_handle ~ '^_|_$' or p_handle ~ '__' then
    return 'format';
  end if;
  if p_handle ~ '^[0-9_]+$' then
    return 'format';
  end if;
  select r.reason into v_reason
  from app_private.reserved_handles r
  where (r.kind = 'exact'    and (v_key = r.term or replace(v_low, '_', '') = r.term))
     or (r.kind = 'contains' and (position(r.term in v_key) > 0 or position(r.term in replace(v_low, '_', '')) > 0))
     or (r.kind = 'regex'    and (v_key ~ r.term or replace(v_low, '_', '') ~ r.term))
  order by case r.reason when 'profanity' then 1 when 'impersonation' then 2 else 3 end
  limit 1;
  return v_reason; -- null when fine
end;
$$;
revoke all on function app_private.handle_problem(text) from public, anon, authenticated;
revoke all on function app_private.handle_key(text) from public;
grant execute on function app_private.handle_key(text) to anon, authenticated;

create table if not exists public.profiles (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  handle     text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_handle_format check (handle ~ '^[A-Za-z0-9_]{3,20}$')
);
create unique index if not exists profiles_handle_key_uniq on public.profiles (app_private.handle_key(handle));

alter table public.profiles enable row level security;
-- Collectors may read only their own row directly. Public handles are only
-- ever exposed through the claim RPCs. All writes go through set_handle().
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using ((select auth.uid()) = user_id);
revoke insert, update, delete, truncate on public.profiles from anon, authenticated;
revoke all on public.profiles from anon;
grant select on public.profiles to authenticated;
