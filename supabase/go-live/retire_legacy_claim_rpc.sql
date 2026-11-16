-- APPROVAL-GATED CUTOVER: apply together with v2 launch, not during local build.
-- Existing anonymous claim RPC lets callers claim with a display name and no
-- collector login. Leaving it executable bypasses v2's account requirement.
-- This changes permissions, not existing data. Old live site's claim form will
-- stop working, so deploy v2 in the same maintenance window.
revoke execute on function public.claim_card(text,text,text) from public, anon, authenticated;
revoke execute on function app_private.claim_card(text,text,text) from public, anon, authenticated;
