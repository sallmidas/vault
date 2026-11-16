-- Vault v2 · 3/4 · Crack-the-code puzzle tracking (additive only)
-- Answers live only as bcrypt hashes in the unexposed app_private schema.
-- Nothing here is seeded: symbols stay inactive until the shop owner sets the answers with
--   select app_private.set_puzzle_symbol('006', 3, '<answer>', true);

create table if not exists app_private.puzzle_symbols (
  id          bigint generated always as identity primary key,
  card_no     text not null unique references public.cards (card_no) on delete cascade,
  stage       integer check (stage between 1 and 999),
  answer_hash text not null,
  is_active   boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table app_private.puzzle_symbols enable row level security;
revoke all on app_private.puzzle_symbols from public, anon, authenticated;

create table if not exists app_private.puzzle_discoveries (
  user_id       uuid not null references auth.users (id) on delete cascade,
  symbol_id     bigint not null references app_private.puzzle_symbols (id) on delete cascade,
  discovered_at timestamptz not null default now(),
  primary key (user_id, symbol_id)
);
create index if not exists puzzle_discoveries_symbol_idx on app_private.puzzle_discoveries (symbol_id);
alter table app_private.puzzle_discoveries enable row level security;
revoke all on app_private.puzzle_discoveries from public, anon, authenticated;

create table if not exists app_private.puzzle_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  card_no      text,
  correct      boolean not null,
  attempted_at timestamptz not null default now()
);
create index if not exists puzzle_attempts_user_idx on app_private.puzzle_attempts (user_id, attempted_at);
alter table app_private.puzzle_attempts enable row level security;
revoke all on app_private.puzzle_attempts from public, anon, authenticated;

create or replace function app_private.normalize_answer(p text)
returns text language sql immutable set search_path = ''
as $$ select lower(regexp_replace(coalesce(p, ''), '[^[:alnum:]]', '', 'g')); $$;

-- Admin helper (SQL editor / service role only).
create or replace function app_private.set_puzzle_symbol(p_card_no text, p_stage integer, p_answer text, p_active boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_no text := app_private.normalize_card_no(p_card_no);
begin
  if v_no is null or app_private.normalize_answer(p_answer) = '' then
    raise exception 'card number or answer looks wrong';
  end if;
  insert into app_private.puzzle_symbols (card_no, stage, answer_hash, is_active)
  values (v_no, p_stage, extensions.crypt(app_private.normalize_answer(p_answer), extensions.gen_salt('bf', 10)), p_active)
  on conflict (card_no) do update
    set stage = excluded.stage, answer_hash = excluded.answer_hash, is_active = excluded.is_active;
end;
$$;
revoke all on function app_private.set_puzzle_symbol(text, integer, text, boolean) from public, anon, authenticated;
