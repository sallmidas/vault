-- Vault v2 · 8 · One order + shipping ZIP can unlock more than one card.
-- After Dark gift cards often shipped in the same box as an older numbered card,
-- so lookup_digest must not be unique. Additive only: legacy code-claim path
-- and set_order_zip_key stay intact. Order numbers and ZIPs are still never
-- stored in plaintext or returned by any RPC.

alter table app_private.card_order_zip_keys
  drop constraint if exists card_order_zip_keys_lookup_digest_key;

create index if not exists card_order_zip_keys_lookup_digest_idx
  on app_private.card_order_zip_keys (lookup_digest);

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
  v_keys        app_private.card_order_zip_keys[] := '{}';
  v_key         app_private.card_order_zip_keys%rowtype;
  v_card        public.cards%rowtype;
  v_dummy       text := '$2a$10$VgxWsJ7YIO/PvS2FVJeSteqJzP3844FFkaiBpRkZICGB2SYOyCAi2';
  v_match       boolean := false;
  v_owner       uuid;
  v_claimed_at  timestamptz;
  v_remaining   integer;
  v_cards       jsonb := '[]'::jsonb;
  v_new_count   integer := 0;
  v_mine_count  integer := 0;
  v_other_count integer := 0;
  v_primary     jsonb;
  v_row         record;
begin
  perform pg_advisory_xact_lock(hashtextextended('claim:' || v_uid::text, 0));
  delete from app_private.account_claim_attempts where attempted_at < now() - interval '24 hours';

  select handle into v_handle from public.profiles where user_id = v_uid;
  if v_handle is null then
    return jsonb_build_object('ok', false, 'error', 'no_handle', 'message', 'Pick your collector handle first.');
  end if;

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

  select coalesce(array_agg(k), '{}') into v_keys
    from app_private.card_order_zip_keys k
   where k.lookup_digest = v_digest;

  -- Always evaluate bcrypt so timing does not reveal whether lookup_digest matched.
  if v_keys is null or coalesce(array_length(v_keys, 1), 0) = 0 then
    v_match := extensions.crypt(v_order, v_dummy) = v_dummy
           and extensions.crypt(v_zip,   v_dummy) = v_dummy;
  else
    v_match := true;
    foreach v_key in array v_keys loop
      if extensions.crypt(v_order, v_key.order_hash) is distinct from v_key.order_hash
         or extensions.crypt(v_zip, v_key.zip_hash) is distinct from v_key.zip_hash then
        v_match := false;
      end if;
    end loop;
  end if;

  if v_match and v_expected_no is not null then
    v_match := false;
    foreach v_key in array v_keys loop
      if v_key.card_no = v_expected_no then
        v_match := true;
      end if;
    end loop;
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

  -- Lock matching card rows in number order to keep one claim per card under concurrency.
  for v_row in
    select k.card_no
      from unnest(v_keys) as k
     order by k.card_no
  loop
    select * into v_card from public.cards where card_no = v_row.card_no for update;
    if not found then
      continue;
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
      if v_owner = v_uid then
        v_mine_count := v_mine_count + 1;
        v_cards := v_cards || jsonb_build_array(jsonb_build_object(
          'card_no', v_card.card_no,
          'character', v_card.character,
          'edition', v_card.edition,
          'already_mine', true
        ));
        if v_primary is null then
          v_primary := jsonb_build_object(
            'card_no', v_card.card_no,
            'character', v_card.character,
            'edition', v_card.edition
          );
        end if;
      else
        v_other_count := v_other_count + 1;
      end if;
      continue;
    end if;

    insert into public.claims (card_no, display_name, user_id, claim_method)
    values (v_card.card_no, v_handle, v_uid, 'order')
    returning claimed_at into v_claimed_at;

    v_new_count := v_new_count + 1;
    v_cards := v_cards || jsonb_build_array(jsonb_build_object(
      'card_no', v_card.card_no,
      'character', v_card.character,
      'edition', v_card.edition,
      'already_mine', false
    ));
    -- Prefer a newly claimed card as the backward-compatible primary result.
    v_primary := jsonb_build_object(
      'card_no', v_card.card_no,
      'character', v_card.character,
      'edition', v_card.edition
    );
  end loop;

  if v_new_count = 0 and v_mine_count = 0 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, coalesce(v_expected_no, (v_keys)[1].card_no), 'already_claimed');
    return jsonb_build_object('ok', false, 'error', 'already_claimed', 'message', 'This card has already been claimed.');
  end if;

  if v_new_count > 0 then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome)
    values (v_uid, v_primary->>'card_no', 'ok');
  else
    insert into app_private.account_claim_attempts (user_id, card_no, outcome)
    values (v_uid, v_primary->>'card_no', 'already_claimed');
  end if;

  return jsonb_build_object(
    'ok', true,
    'already_mine', (v_new_count = 0),
    'card_no', v_primary->>'card_no',
    'character', v_primary->>'character',
    'edition', v_primary->>'edition',
    'handle', v_handle,
    'claimed_at', v_claimed_at,
    'count', v_new_count + v_mine_count,
    'cards', v_cards
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
