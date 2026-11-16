# Vault v2 — Supabase (project yzfhecjvuorvvsrfoktt, "Vault Cards")

All changes are additive. Existing `cards` / `claims` rows are untouched.

## Migrations (applied to the live project 2026-11-16)
1. `20261116190000_vault_v2_profiles_handles.sql`: `public.profiles` plus the handle rules (reserved, impersonation and profanity guards with leet-folding).
2. `20261116190100_vault_v2_account_claims.sql`: `claims.user_id` and `claims.claim_method`; bcrypt order keys in `app_private.card_order_keys`; attempt throttling; cards 003, 004 and 013 inserted; `founder_entitlements` table (empty).
3. `20261116190200_vault_v2_puzzle.sql`: private puzzle tables. Answers are stored only as hashes. Nothing is seeded.
4. `20261116190300_vault_v2_rpcs.sql`: the RPCs. SECURITY DEFINER functions live in `app_private`; thin invoker wrappers live in `public`.

## Admin snippets (run in the SQL editor; never commit real values)
```sql
select app_private.set_order_key('006', '<order number>');
select app_private.set_puzzle_symbol('002', 1, '<answer>', true);
insert into app_private.founder_entitlements (card_no, series_no, status) values ('002', 1, 'issued');
```

## At cutover
Run `go-live/retire_legacy_claim_rpc.sql`. It closes the old anonymous `claim_card` RPC.
