-- Vault v2 · 4/4 · RPCs for accounts, claims, card pages, the wall and My Vault.
-- Pattern (same as the existing card_status / claim_card): SECURITY DEFINER
-- logic lives in the unexposed app_private schema; thin SECURITY INVOKER
-- wrappers in public are what PostgREST exposes. No RPC ever returns an order
-- number, claim code, email address, user id or puzzle answer.

-- ---------- helpers ----------
create or replace function app_private.require_uid()
returns uuid language plpgsql stable set search_path = ''
as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'sign in required' using errcode = '28000'; end if;
  return v;
end;
$$;

-- ---------- handles ----------
create or replace function app_private.my_profile()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('handle', p.handle, 'created_at', p.created_at)
       from public.profiles p where p.user_id = auth.uid()),
    'null'::jsonb);
$$;

create or replace function app_private.check_handle(p_handle text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_problem text := app_private.handle_problem(btrim(coalesce(p_handle, '')));
begin
  if v_problem is not null then
    return jsonb_build_object('ok', false, 'error', v_problem);
  end if;
  if exists (select 1 from public.profiles p
             where app_private.handle_key(p.handle) = app_private.handle_key(btrim(p_handle))
               and p.user_id is distinct from auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function app_private.set_handle(p_handle text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_handle text := btrim(coalesce(p_handle, ''));
  v_check jsonb;
  v_prev public.profiles%rowtype;
begin
  v_check := app_private.check_handle(v_handle);
  if (v_check->>'ok')::boolean is not true then
    return v_check || jsonb_build_object('message', case v_check->>'error'
      when 'format' then 'Use 3–20 letters, numbers or single underscores.'
      when 'taken' then 'That handle is already taken.'
      when 'profanity' then 'Please pick a different handle.'
      else 'That handle is reserved. Please pick another.' end);
  end if;
  select * into v_prev from public.profiles where user_id = v_uid for update;
  if found then
    if v_prev.handle = v_handle then
      return jsonb_build_object('ok', true, 'handle', v_handle);
    end if;
    if v_prev.updated_at > now() - interval '7 days' and v_prev.updated_at > v_prev.created_at + interval '10 minutes' then
      return jsonb_build_object('ok', false, 'error', 'cooldown', 'message', 'You can change your handle once a week.');
    end if;
    update public.profiles set handle = v_handle, updated_at = now() where user_id = v_uid;
  else
    insert into public.profiles (user_id, handle) values (v_uid, v_handle);
  end if;
  update public.claims set display_name = v_handle where user_id = v_uid;
  return jsonb_build_object('ok', true, 'handle', v_handle);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'taken', 'message', 'That handle is already taken.');
end;
$$;

-- ---------- claiming ----------
create or replace function app_private.claim_card_account(p_card_no text, p_key text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_no text := app_private.normalize_card_no(p_card_no);
  v_digits text := regexp_replace(coalesce(p_key, ''), '\D', '', 'g');
  v_code text := app_private.normalize_claim_code(p_key);
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
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Check the card number and order number, then try again.');
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

  -- Key 1: the eBay order number printed on the card (digits only).
  if char_length(v_digits) >= 8
     and extensions.crypt(v_digits, coalesce(v_order_hash, v_dummy)) = coalesce(v_order_hash, v_dummy)
     and v_order_hash is not null and v_card.card_no is not null then
    v_method := 'order';
  -- Key 2: the private claim code (scratch-off / slip), if one was issued.
  elsif char_length(v_code) between 6 and 12
     and extensions.crypt(v_code, coalesce(v_card.claim_code_hash, v_dummy)) = coalesce(v_card.claim_code_hash, v_dummy)
     and v_card.card_no is not null then
    v_method := 'code';
  end if;

  if v_method is null then
    insert into app_private.account_claim_attempts (user_id, card_no, outcome) values (v_uid, v_no, 'fail');
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'That order number doesn''t match this card.');
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

-- ---------- public reads ----------
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
    'is_mine', v_claim.user_id is not null and v_claim.user_id = auth.uid());
end;
$$;

create or replace function app_private.claimed_wall()
returns jsonb language sql stable security definer set search_path = ''
as $$
  with c as (
    select cl.card_no, cd.character, cd.edition, cl.claimed_at, cl.user_id,
           coalesce(p.handle, cl.display_name) as name, p.handle is not null as is_handle
    from public.claims cl
    join public.cards cd on cd.card_no = cl.card_no
    left join public.profiles p on p.user_id = cl.user_id
  ), board as (
    select name, is_handle, count(*) as cards, min(claimed_at) as first_claim
    from c group by name, is_handle, user_id
  )
  select jsonb_build_object(
    'claims', coalesce((select jsonb_agg(jsonb_build_object('card_no', card_no, 'character', character,
               'edition', edition, 'name', name, 'is_handle', is_handle, 'claimed_at', claimed_at)
               order by claimed_at desc) from c), '[]'::jsonb),
    'leaders', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'is_handle', is_handle,
               'cards', cards, 'first_claim', first_claim) order by cards desc, first_claim asc)
               from (select * from board order by cards desc, first_claim asc limit 50) b), '[]'::jsonb),
    'registered', (select count(*) from public.cards),
    'claimed', (select count(*) from c));
$$;

-- ---------- My Vault ----------
create or replace function app_private.my_vault()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_profile public.profiles%rowtype;
begin
  select * into v_profile from public.profiles where user_id = v_uid;
  return jsonb_build_object(
    'handle', v_profile.handle,
    'member_since', v_profile.created_at,
    'founders_spots', coalesce((select jsonb_agg(jsonb_build_object('card_no', f.card_no, 'series_no', f.series_no, 'status', f.status))
       from app_private.founder_entitlements f join public.claims cl on cl.card_no=f.card_no where cl.user_id=v_uid), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('card_no', cl.card_no, 'character', cd.character,
               'edition', cd.edition, 'claimed_at', cl.claimed_at) order by cl.card_no)
               from public.claims cl join public.cards cd on cd.card_no = cl.card_no
               where cl.user_id = v_uid), '[]'::jsonb),
    'puzzle', jsonb_build_object(
      'total', (select count(*) from app_private.puzzle_symbols where is_active),
      'found', (select count(*) from app_private.puzzle_discoveries d
                 join app_private.puzzle_symbols s on s.id = d.symbol_id
                 where d.user_id = v_uid and s.is_active),
      'discoveries', coalesce((select jsonb_agg(jsonb_build_object('card_no', s.card_no, 'stage', s.stage,
               'discovered_at', d.discovered_at) order by s.stage nulls last)
               from app_private.puzzle_discoveries d join app_private.puzzle_symbols s on s.id = d.symbol_id
               where d.user_id = v_uid and s.is_active), '[]'::jsonb),
      'open_cards', coalesce((select jsonb_agg(s.card_no order by s.card_no)
               from app_private.puzzle_symbols s where s.is_active), '[]'::jsonb)));
end;
$$;

-- ---------- puzzle ----------
create or replace function app_private.submit_symbol(p_card_no text, p_answer text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_uid();
  v_no text := app_private.normalize_card_no(p_card_no);
  v_ans text := app_private.normalize_answer(p_answer);
  v_sym app_private.puzzle_symbols%rowtype;
  v_ok boolean := false;
begin
  perform pg_advisory_xact_lock(hashtextextended('puzzle:' || v_uid::text, 0));
  delete from app_private.puzzle_attempts where attempted_at < now() - interval '7 days';
  if (select count(*) from app_private.puzzle_attempts
        where user_id = v_uid and not correct and attempted_at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'throttled', 'message', 'Too many guesses. Try again in 15 minutes.');
  end if;
  select * into v_sym from app_private.puzzle_symbols where card_no = v_no and is_active;
  if not found or v_ans = '' or char_length(v_ans) > 40 then
    return jsonb_build_object('ok', false, 'error', 'closed', 'message', 'This symbol isn''t open yet.');
  end if;
  v_ok := extensions.crypt(v_ans, v_sym.answer_hash) = v_sym.answer_hash;
  insert into app_private.puzzle_attempts (user_id, card_no, correct) values (v_uid, v_no, v_ok);
  if v_ok then
    insert into app_private.puzzle_discoveries (user_id, symbol_id) values (v_uid, v_sym.id)
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'correct', v_ok,
    'found', (select count(*) from app_private.puzzle_discoveries d join app_private.puzzle_symbols s on s.id = d.symbol_id
              where d.user_id = v_uid and s.is_active),
    'total', (select count(*) from app_private.puzzle_symbols where is_active));
end;
$$;

-- ---------- privileges on app_private ----------
revoke all on function app_private.require_uid() from public;
revoke all on function app_private.my_profile() from public;
revoke all on function app_private.check_handle(text) from public;
revoke all on function app_private.set_handle(text) from public;
revoke all on function app_private.claim_card_account(text, text) from public;
revoke all on function app_private.card_page(text) from public;
revoke all on function app_private.claimed_wall() from public;
revoke all on function app_private.my_vault() from public;
revoke all on function app_private.submit_symbol(text, text) from public;
revoke all on function app_private.normalize_answer(text) from public;
revoke all on function app_private.require_uid(), app_private.my_profile(), app_private.check_handle(text),
  app_private.set_handle(text), app_private.claim_card_account(text, text), app_private.my_vault(),
  app_private.submit_symbol(text, text), app_private.normalize_answer(text) from anon;
grant execute on function app_private.require_uid(), app_private.my_profile(), app_private.check_handle(text),
  app_private.set_handle(text), app_private.claim_card_account(text, text), app_private.my_vault(),
  app_private.submit_symbol(text, text) to authenticated;
grant execute on function app_private.card_page(text), app_private.claimed_wall() to anon, authenticated;

-- ---------- public wrappers (SECURITY INVOKER) ----------
create or replace function public.my_profile() returns jsonb language sql stable set search_path = ''
as $$ select app_private.my_profile(); $$;
create or replace function public.check_handle(handle text) returns jsonb language sql stable set search_path = ''
as $$ select app_private.check_handle(handle); $$;
create or replace function public.set_handle(handle text) returns jsonb language sql set search_path = ''
as $$ select app_private.set_handle(handle); $$;
create or replace function public.claim_card_account(card_no text, order_key text) returns jsonb language sql set search_path = ''
as $$ select app_private.claim_card_account(card_no, order_key); $$;
create or replace function public.card_page(card_no text) returns jsonb language sql stable set search_path = ''
as $$ select app_private.card_page(card_no); $$;
create or replace function public.claimed_wall() returns jsonb language sql stable set search_path = ''
as $$ select app_private.claimed_wall(); $$;
create or replace function public.my_vault() returns jsonb language sql stable set search_path = ''
as $$ select app_private.my_vault(); $$;
create or replace function public.submit_symbol(card_no text, answer text) returns jsonb language sql set search_path = ''
as $$ select app_private.submit_symbol(card_no, answer); $$;

revoke all on function public.my_profile(), public.check_handle(text), public.set_handle(text),
  public.claim_card_account(text, text), public.card_page(text), public.claimed_wall(),
  public.my_vault(), public.submit_symbol(text, text) from public, anon, authenticated;
grant execute on function public.my_profile(), public.check_handle(text), public.set_handle(text),
  public.claim_card_account(text, text), public.my_vault(), public.submit_symbol(text, text) to authenticated;
grant execute on function public.card_page(text), public.claimed_wall() to anon, authenticated;
