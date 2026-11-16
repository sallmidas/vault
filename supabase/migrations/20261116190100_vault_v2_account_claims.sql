-- Vault v2 · 2/4 · Link claims to collector accounts, private order keys (additive only)

alter table public.claims add column if not exists user_id uuid references auth.users (id) on delete set null;
alter table public.claims add column if not exists claim_method text
  check (claim_method in ('order', 'code'));
create index if not exists claims_user_id_idx on public.claims (user_id);
-- claims.card_no is already the primary key, so a card can be claimed exactly once.
-- The existing claims_deny_api policy (anon, authenticated: false) stays, so
-- claims can only be written by the SECURITY DEFINER RPC below.

-- Private: bcrypt hash of each card's eBay order number (digits only).
-- Never stored in plain text, never returned by any RPC.
create table if not exists app_private.card_order_keys (
  card_no    text primary key references public.cards (card_no) on delete cascade,
  order_hash text not null,
  created_at timestamptz not null default now()
);
alter table app_private.card_order_keys enable row level security;
revoke all on app_private.card_order_keys from public, anon, authenticated;

create table if not exists app_private.account_claim_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid,
  card_no      text,
  outcome      text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists account_claim_attempts_user_idx on app_private.account_claim_attempts (user_id, attempted_at);
create index if not exists account_claim_attempts_card_idx on app_private.account_claim_attempts (card_no, attempted_at);
alter table app_private.account_claim_attempts enable row level security;
revoke all on app_private.account_claim_attempts from public, anon, authenticated;

-- Admin helper (run in the SQL editor as postgres / service role only):
--   select app_private.set_order_key('014', '12-34567-89012');
create or replace function app_private.set_order_key(p_card_no text, p_order text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_no text := app_private.normalize_card_no(p_card_no);
  v_digits text := regexp_replace(coalesce(p_order, ''), '\D', '', 'g');
begin
  if v_no is null or char_length(v_digits) < 8 then
    raise exception 'card number or order number looks wrong';
  end if;
  insert into app_private.card_order_keys (card_no, order_hash)
  values (v_no, extensions.crypt(v_digits, extensions.gen_salt('bf', 10)))
  on conflict (card_no) do update set order_hash = excluded.order_hash, created_at = now();
end;
$$;
revoke all on function app_private.set_order_key(text, text) from public, anon, authenticated;

-- Register the sold cards that were not in the registry yet. Their legacy
-- claim_code_hash is an unusable random hash, so the order number is their key.
insert into public.cards (card_no, character, edition, issued_at, claim_code_hash) values
  ('003', 'Ragnar & Lagertha', 'Collector · #177 & #178', null, extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf', 10))),
  ('004', 'Locust Drone',      'Collector · #117',        null, extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf', 10))),
  ('013', 'Alien Queen',       'Collector · #1171',       '2026-11-16 05:00:00+00', extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf', 10)))
on conflict (card_no) do nothing;

-- Founder's Series (about 100) spots are sold as eBay upgrades, so they are
-- admin-assigned per card, never automatic.
create table if not exists app_private.founder_entitlements (
  card_no text primary key references public.cards(card_no) on delete cascade,
  series_no integer unique check (series_no between 1 and 100),
  status text not null check (status in ('reserved', 'issued')),
  granted_at timestamptz not null default now()
);
alter table app_private.founder_entitlements enable row level security;
revoke all on app_private.founder_entitlements from public, anon, authenticated;
-- Left empty on purpose: the shop owner assigns Founder's Series numbers when an upgrade sells.
-- Admin: insert into app_private.founder_entitlements (card_no, series_no, status) values ('005', 1, 'issued');
