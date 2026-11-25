-- Vault v2 · 7 · Claim by order number + shipping ZIP (no claim slips or QR codes).
-- Additive only: existing code-claim RPC (claim_card_account) and legacy tables stay intact
-- so older cards with sealed claim codes can still be claimed.
--
-- Security model:
--   - Order numbers and shipping ZIPs are NEVER stored in plaintext and NEVER returned by any RPC.
--   - app_private.card_order_zip_keys stores a salted SHA-256 lookup digest (for O(1) resolution of
--     (order_number, shipping_zip) -> card_no) plus separate bcrypt hashes for order_number and zip.
--   - Rate-limiting / lockout: 5 failed attempts by an account within 15 minutes locks claiming for
--     15 minutes (and 8 failed attempts on a single card within 15 minutes locks that card).
--   - All tables and private helpers live in app_private with RLS enabled and all grants revoked.
--
-- Admin helper (run in the Supabase SQL editor as postgres / service role only; example values):
--   select app_private.set_order_zip_key('018', '00-00000-00000', '00000', 'ebay');

create table if not exists app_private.card_order_zip_keys (
  card_no       text primary key references public.cards (card_no) on delete cascade,
  lookup_digest text not null unique check (lookup_digest ~ '^[0-9a-f]{64}$'),
  order_hash    text not null check (order_hash ~ '^\$2[ab]\$[0-9]{2}\$.{53}$'),
  zip_hash      text not null check (zip_hash ~ '^\$2[ab]\$[0-9]{2}\$.{53}$'),
  platform      text not null default 'ebay' check (platform in ('ebay', 'mercari', 'other')),
  created_at    timestamptz not null default now()
);
alter table app_private.card_order_zip_keys enable row level security;
revoke all on app_private.card_order_zip_keys from public, anon, authenticated;

-- Normalize eBay (e.g. 12-34567-89012 -> 123456789012) and Mercari (e.g. m12345678901 -> M12345678901).
create or replace function app_private.normalize_order_number(p_order text)
returns text language sql immutable set search_path = ''
as $$
  select case
    when char_length(s.k) between 6 and 32 then s.k
    else null
  end
  from (select upper(regexp_replace(coalesce(p_order, ''), '[^A-Za-z0-9]', '', 'g')) as k) s;
$$;

-- Normalize shipping ZIP: US 5-digit or ZIP+4 folds to 5 digits; international postal codes keep 3..10 alphanumerics.
create or replace function app_private.normalize_shipping_zip(p_zip text)
returns text language sql immutable set search_path = ''
as $$
  select case
    when btrim(coalesce(p_zip, '')) ~ '^[0-9]{5}([- ]?[0-9]{4})?$'
      then substring(regexp_replace(p_zip, '\D', '', 'g') from 1 for 5)
    when char_length(regexp_replace(upper(coalesce(p_zip, '')), '[^A-Z0-9]', '', 'g')) between 3 and 10
      then regexp_replace(upper(coalesce(p_zip, '')), '[^A-Z0-9]', '', 'g')
    else null
  end;
$$;

create or replace function app_private.order_zip_lookup_digest(p_norm_order text, p_norm_zip text)
returns text language sql immutable set search_path = ''
as $$
  select encode(
    extensions.digest(convert_to('vs-order-zip-v1:' || coalesce(p_norm_order, '') || ':' || coalesce(p_norm_zip, ''), 'UTF8'), 'sha256'),
    'hex'
  );
$$;

-- Admin-only setter (SQL editor / service role). Never exposed to anon or authenticated.
create or replace function app_private.set_order_zip_key(
  p_card_no  text,
  p_order    text,
  p_zip      text,
  p_platform text default 'ebay'
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_no       text := app_private.normalize_card_no(p_card_no);
  v_order    text := app_private.normalize_order_number(p_order);
  v_zip      text := app_private.normalize_shipping_zip(p_zip);
  v_platform text := lower(btrim(coalesce(p_platform, 'ebay')));
begin
  if v_no is null or not exists (select 1 from public.cards where card_no = v_no) then
    raise exception 'unknown card %', p_card_no;
  end if;
  if v_order is null or v_zip is null then
    raise exception 'order number or shipping ZIP looks invalid';
  end if;
  if v_platform not in ('ebay', 'mercari', 'other') then
    raise exception 'invalid platform %', p_platform;
  end if;

  insert into app_private.card_order_zip_keys (card_no, lookup_digest, order_hash, zip_hash, platform)
  values (
    v_no,
    app_private.order_zip_lookup_digest(v_order, v_zip),
    extensions.crypt(v_order, extensions.gen_salt('bf', 10)),
    extensions.crypt(v_zip, extensions.gen_salt('bf', 10)),
    v_platform
  )
  on conflict (card_no) do update set
    lookup_digest = excluded.lookup_digest,
    order_hash    = excluded.order_hash,
    zip_hash      = excluded.zip_hash,
    platform      = excluded.platform,
    created_at    = now();
end;
$$;

revoke all on function app_private.normalize_order_number(text),
  app_private.normalize_shipping_zip(text),
  app_private.order_zip_lookup_digest(text, text),
  app_private.set_order_zip_key(text, text, text, text)
  from public, anon, authenticated;

-- Collector RPC: match (order_number, shipping_zip) -> card_no and claim into the signed-in user's vault.
-- Optional p_card_no pins the check to a specific card page when claiming from /?card=NNN.
create or replace function app_private.claim_card_by_order(
  p_order   text,
  p_zip     text,
  p_card_no text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid         uuid := app_private.require_uid();
  v_expected_no text := case when nullif(btrim(coalesce(p_card_no, '')), '') is null then null else app_private.normalize_card_no(p_card_no) end;
  v_order       text := app_private.normalize_order_number(p_order);
  v_zip         text := app_private.normalize_shipping_zip(p_zip);
  v_handle      text;
  v_user_fails  integer := 0;
  v_digest      text;
  v_key         app_private.card_order_zip_keys%rowtype;
  v_card        public.cards%rowtype;
  v_dummy       text := '$2a$10$VgxWsJ7YIO/PvS2FVJeSteqJzP3844FFkaiBpRkZICGB2SYOyCAi2';
  v_match       boolean := false;
  v_owner       uuid;
  v_claimed_at  timestamptz;
  v_remaining   integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('claim:' || v_uid::text, 0));
  delete from app_private.account_claim_attempts where attempted_at < now() - interval '24 hours';

  select handle into v_handle from public.profiles where user_id = v_uid;
  if v_handle is null then
    return jsonb_build_object('ok', false, 'error', 'no_handle', 'message', 'Pick your collector handle first.');
  end if;

  -- Lock out after 5 failed tries within 15 minutes so no one can guess order+ZIP pairs.
  select count(*) into v_user_fails
    from app_private.account_claim_attempts
   where user_id = v_uid and outcome = 'fail' and attempted_at > now() - interval '15 minutes';

  if v_user_fails >= 5 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_expected_no, 'throttled');
    return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many failed tries. Claiming is locked for 15 minutes.');
  end if;

  if nullif(btrim(coalesce(p_card_no, '')), '') is not null and v_expected_no is null then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'That card number doesn''t look right.');
  end if;

  if v_order is null or v_zip is null then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Enter your full order number and shipping ZIP code.');
  end if;

  if v_expected_no is not null and (
    select count(*) from app_private.account_claim_attempts
     where card_no = v_expected_no and outcome = 'fail' and attempted_at > now() - interval '15 minutes'
  ) >= 8 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_expected_no, 'throttled');
    return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many failed tries for this card. Please wait 15 minutes.');
  end if;

  v_digest := app_private.order_zip_lookup_digest(v_order, v_zip);
  select * into v_key from app_private.card_order_zip_keys where lookup_digest = v_digest;

  -- Always evaluate bcrypt so timing does not reveal whether lookup_digest matched.
  v_match := found
    and extensions.crypt(v_order, coalesce(v_key.order_hash, v_dummy)) = coalesce(v_key.order_hash, v_dummy)
    and extensions.crypt(v_zip,   coalesce(v_key.zip_hash,   v_dummy)) = coalesce(v_key.zip_hash,   v_dummy);

  if v_match and v_expected_no is not null and v_key.card_no <> v_expected_no then
    v_match := false;
  end if;

  if not v_match then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_expected_no, 'fail');
    v_remaining := greatest(0, 4 - v_user_fails);
    if v_remaining = 0 then
      return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many failed tries. Claiming is locked for 15 minutes.');
    end if;
    return jsonb_build_object(
      'ok', false,
      'error', 'invalid',
      'message', 'That order number and shipping ZIP didn''t match a Vault Card. (' || v_remaining || case when v_remaining = 1 then ' try' else ' tries' end || ' left before a 15-minute lock.)'
    );
  end if;

  -- Lock the matched card row to enforce one claim per card under concurrency.
  select * into v_card from public.cards where card_no = v_key.card_no for update;
  if not found then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_key.card_no, 'fail');
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'That order number and shipping ZIP didn''t match a Vault Card.');
  end if;

  if (
    select count(*) from app_private.account_claim_attempts
     where card_no = v_card.card_no and outcome = 'fail' and attempted_at > now() - interval '15 minutes'
  ) >= 8 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_card.card_no, 'throttled');
    return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many failed tries for this card. Please wait 15 minutes.');
  end if;

  select user_id into v_owner from public.claims where card_no = v_card.card_no;
  if found then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_card.card_no, 'already_claimed');
    if v_owner = v_uid then
      return jsonb_build_object(
        'ok', true,
        'already_mine', true,
        'card_no', v_card.card_no,
        'character', v_card.character,
        'edition', v_card.edition,
        'handle', v_handle
      );
    end if;
    return jsonb_build_object('ok', false, 'error', 'already_claimed', 'message', 'This card has already been claimed.');
  end if;

  insert into public.claims (card_no, display_name, user_id, claim_method)
  values (v_card.card_no, v_handle, v_uid, 'order')
  returning claimed_at into v_claimed_at;

  insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_card.card_no, 'ok');

  return jsonb_build_object(
    'ok', true,
    'card_no', v_card.card_no,
    'character', v_card.character,
    'edition', v_card.edition,
    'handle', v_handle,
    'claimed_at', v_claimed_at
  );
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'already_claimed', 'message', 'This card has already been claimed.');
end;
$$;

revoke all on function app_private.claim_card_by_order(text, text, text) from public, anon;
grant execute on function app_private.claim_card_by_order(text, text, text) to authenticated;

create or replace function public.claim_card_by_order(
  order_number text,
  shipping_zip text,
  card_no      text default null
)
returns jsonb language sql set search_path = ''
as $$ select app_private.claim_card_by_order(order_number, shipping_zip, card_no); $$;

revoke all on function public.claim_card_by_order(text, text, text) from public, anon, authenticated;
grant execute on function public.claim_card_by_order(text, text, text) to authenticated;
