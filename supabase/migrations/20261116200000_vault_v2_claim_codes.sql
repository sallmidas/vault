-- Vault v2 · 5 · Private per-card claim codes (VS-XXXX-XX), additive only.
-- Plaintext codes never touch the database, the repo or the browser: they are
-- generated offline (tools/issue_claim_codes.py) and only a bcrypt hash is stored.
-- The legacy cards.claim_code_hash and the v1 claim_card RPC are left untouched.

create table if not exists app_private.card_claim_codes (
  id         bigint generated always as identity primary key,
  card_no    text not null references public.cards (card_no) on delete cascade,
  code_hash  text not null check (code_hash ~ '^\$2[ab]\$[0-9]{2}\$.{53}$'),
  holder     text not null default 'buyer' check (holder in ('buyer', 'founder')),
  issued_at  timestamptz not null default now(),
  revoked_at timestamptz
);
-- One live code per card; re-issuing revokes the old one.
create unique index if not exists card_claim_codes_one_active
  on app_private.card_claim_codes (card_no) where revoked_at is null;
alter table app_private.card_claim_codes enable row level security;
revoke all on app_private.card_claim_codes from public, anon, authenticated;

-- VS-XXXX-XX → VSXXXXXX. Alphabet has no 0/O/1/I/L, so strip separators,
-- upper-case, and add the VS prefix when a collector leaves it off.
create or replace function app_private.normalize_vault_code(p_code text)
returns text language sql immutable set search_path = ''
as $$
  select case
    when k ~ '^VS[2-9A-HJKMNP-Z]{6}$' then k
    when k ~ '^[2-9A-HJKMNP-Z]{6}$' then 'VS' || k
    else null end
  from (select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')) as k) s;
$$;

-- Admin only (SQL editor / service role). Takes a bcrypt hash made offline.
create or replace function app_private.set_claim_code_hash(p_card_no text, p_hash text, p_holder text default 'buyer')
returns void language plpgsql security definer set search_path = ''
as $$
declare v_no text := app_private.normalize_card_no(p_card_no);
begin
  if v_no is null or not exists (select 1 from public.cards where card_no = v_no) then
    raise exception 'unknown card %', p_card_no;
  end if;
  update app_private.card_claim_codes set revoked_at = now() where card_no = v_no and revoked_at is null;
  insert into app_private.card_claim_codes (card_no, code_hash, holder) values (v_no, p_hash, p_holder);
end;
$$;
revoke all on function app_private.set_claim_code_hash(text, text, text) from public, anon, authenticated;
revoke all on function app_private.normalize_vault_code(text) from public, anon;

create or replace function app_private.claim_card_account(p_card_no text, p_key text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_no text := app_private.normalize_card_no(p_card_no);
  v_digits text := regexp_replace(coalesce(p_key, ''), '\D', '', 'g');
  v_code text := app_private.normalize_claim_code(p_key);
  v_vcode text := app_private.normalize_vault_code(p_key);
  v_code_hash text;
  v_handle text;
  v_card public.cards%rowtype;
  v_order_hash text;
  v_dummy text := '$2a$10$VgxWsJ7YIO/PvS2FVJeSteqJzP3844FFkaiBpRkZICGB2SYOyCAi2';
  v_method text;
  v_claimed_at timestamptz;
  v_owner uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('claim:' || v_uid::text, 0));
  -- Lock card before counting attempts, so parallel requests cannot bypass the cap.
  perform 1 from public.cards where card_no = v_no for update;
  delete from app_private.account_claim_attempts where attempted_at < now() - interval '24 hours';

  select handle into v_handle from public.profiles where user_id = v_uid;
  if v_handle is null then
    return jsonb_build_object('ok', false, 'error', 'no_handle', 'message', 'Pick your collector handle first.');
  end if;
  if v_no is null or char_length(coalesce(p_key, '')) < 6 or char_length(p_key) > 40 then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Check the card number and claim code, then try again.');
  end if;

  if (select count(*) from app_private.account_claim_attempts
        where user_id = v_uid and outcome = 'fail' and attempted_at > now() - interval '15 minutes') >= 6
     or (select count(*) from app_private.account_claim_attempts
        where card_no = v_no and outcome = 'fail' and attempted_at > now() - interval '15 minutes') >= 8 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_no, 'throttled');
    return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many tries. Please wait 15 minutes.');
  end if;

  select * into v_card from public.cards where card_no = v_no for update;
  select order_hash into v_order_hash from app_private.card_order_keys where card_no = v_no;

  select code_hash into v_code_hash from app_private.card_claim_codes
   where card_no = v_no and revoked_at is null;

  -- Key 1 (main): the private Vault claim code from the insert (VS-XXXX-XX).
  if v_vcode is not null
     and extensions.crypt(v_vcode, coalesce(v_code_hash, v_dummy)) = coalesce(v_code_hash, v_dummy)
     and v_code_hash is not null and v_card.card_no is not null then
    v_method := 'code';
  -- Key 2 (fallback): the eBay order number, only for cards that sold and have one on file.
  elsif char_length(v_digits) >= 8
     and extensions.crypt(v_digits, coalesce(v_order_hash, v_dummy)) = coalesce(v_order_hash, v_dummy)
     and v_order_hash is not null and v_card.card_no is not null then
    v_method := 'order';
  -- Key 3 (legacy): the v1 claim code, only while no v2 code has been issued for the card.
  elsif v_code_hash is null and char_length(v_code) between 6 and 12
     and extensions.crypt(v_code, coalesce(v_card.claim_code_hash, v_dummy)) = coalesce(v_card.claim_code_hash, v_dummy)
     and v_card.card_no is not null then
    v_method := 'code';
  end if;

  if v_method is null then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_no, 'fail');
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'That claim code or order number doesn''t match this card.');
  end if;

  select user_id into v_owner from public.claims where card_no = v_no;
  if found then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_no, 'already_claimed');
    if v_owner = v_uid then
      return jsonb_build_object('ok', true, 'already_mine', true, 'card_no', v_no, 'handle', v_handle);
    end if;
    return jsonb_build_object('ok', false, 'error', 'already_claimed', 'message', 'This card has already been claimed.');
  end if;

  insert into public.claims (card_no, display_name, user_id, claim_method)
  values (v_no, v_handle, v_uid, v_method)
  returning claimed_at into v_claimed_at;
  insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_no, 'ok');

  return jsonb_build_object('ok', true, 'card_no', v_no, 'character', v_card.character,
    'edition', v_card.edition, 'handle', v_handle, 'claimed_at', v_claimed_at);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'already_claimed', 'message', 'This card has already been claimed.');
end;
$$;


create or replace function app_private.card_page(p_card_no text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_no text := app_private.normalize_card_no(p_card_no);
  v_card public.cards%rowtype;
  v_claim public.claims%rowtype;
  v_handle text;
begin
  if v_no is null then return jsonb_build_object('found', false); end if;
  select * into v_card from public.cards where card_no = v_no;
  if not found then return jsonb_build_object('found', false, 'card_no', v_no); end if;
  select * into v_claim from public.claims where card_no = v_no;
  if v_claim.user_id is not null then
    select handle into v_handle from public.profiles where user_id = v_claim.user_id;
  end if;
  return jsonb_build_object(
    'found', true, 'card_no', v_card.card_no, 'character', v_card.character, 'edition', v_card.edition,
    'claimed', v_claim.card_no is not null,
    'handle', v_handle,
    'display_name', case when v_claim.card_no is null then null else coalesce(v_handle, v_claim.display_name) end,
    'claimed_at', v_claim.claimed_at,
    'is_mine', v_claim.user_id is not null and v_claim.user_id = auth.uid(),
    'awaits_founder', v_claim.card_no is null and exists (
       select 1 from app_private.card_claim_codes k
        where k.card_no = v_no and k.revoked_at is null and k.holder = 'founder'));
end;
$$;

