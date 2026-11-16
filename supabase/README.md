# Vault v2 — Supabase (project yzfhecjvuorvvsrfoktt, "Vault Cards")

All changes are additive. Existing `cards` / `claims` rows are untouched.

## Migrations (applied to the live project 2026-11-16)
1. `20261116190000_vault_v2_profiles_handles.sql`: `public.profiles` plus the handle rules (reserved, impersonation and profanity guards with leet-folding).
2. `20261116190100_vault_v2_account_claims.sql`: `claims.user_id` and `claims.claim_method`; bcrypt order keys in `app_private.card_order_keys`; attempt throttling; cards 003, 004 and 013 inserted; `founder_entitlements` table (empty).
3. `20261116190200_vault_v2_puzzle.sql`: private puzzle tables. Answers are stored only as hashes. Nothing is seeded.
4. `20261116190300_vault_v2_rpcs.sql`: the RPCs. SECURITY DEFINER functions live in `app_private`; thin invoker wrappers live in `public`.
5. `20261116200000_vault_v2_claim_codes.sql`: private per-card claim codes (`VS-XXXX-XX`, no 0/O/1/I/L). Only bcrypt hashes are stored, in `app_private.card_claim_codes` (one active per card, `holder` = buyer | founder). `claim_card_account` checks keys in this order: claim code, then eBay order number (only for sold cards with one on file), then the v1 code (only while no v2 code exists). `card_page` adds `awaits_founder`.

## Issuing claim codes (cards 014+)
Plaintext codes never go in this repo, the database or the browser.
1. On the box, run `python3 /workspace/vault-v2/tools/issue_claim_codes.py 014` (add `--founder 0NN` for a Founder card, or `--reissue` to replace a lost code). Codes are appended to the private CSV (chmod 600). The script writes a hash-only SQL file next to it.
2. Run that SQL file once in the Supabase SQL editor. It calls `app_private.set_claim_code_hash`, which revokes any older code for the card.
3. Add the card to `assets/vault-data.js`, then run `python3 /workspace/vault-v2/tools/make_inserts.py print` to rebuild the private insert PDFs.
4. If the card sold before it had an insert: `select app_private.set_order_key('014', '<order number>');`

## Admin snippets (run in the SQL editor; never commit real values)
```sql
select app_private.set_puzzle_symbol('002', 1, '<answer>', true);
insert into app_private.founder_entitlements (card_no, series_no, status) values ('002', 1, 'issued');
```

## At cutover
Run `go-live/retire_legacy_claim_rpc.sql`. It closes the old anonymous `claim_card` RPC.
