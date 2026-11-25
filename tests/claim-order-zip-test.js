/* Fixture-only tests for order-number + shipping-ZIP claiming.
   Values below are obvious fake test examples, never real order numbers or ZIPs. */
"use strict";
var assert = require("assert");
var fs = require("fs");
var path = require("path");
var api = require("../assets/vault-claim-link.js");

var fails = 0;
function check(name, fn) {
  try { fn(); console.log("ok  " + name); }
  catch (e) { fails += 1; console.error("FAIL  " + name + ": " + e.message); }
}

check("normalize eBay and Mercari fake order numbers", function () {
  assert.strictEqual(api.normalizeOrderNumber("00-00000-00000"), "000000000000");
  assert.strictEqual(api.normalizeOrderNumber("  m00000000001 "), "M00000000001");
  assert.strictEqual(api.normalizeOrderNumber("12345"), "");
  assert.strictEqual(api.normalizeOrderNumber(""), "");
});

check("normalize US 5-digit, ZIP+4, and international postal codes", function () {
  assert.strictEqual(api.normalizeShippingZip("00000"), "00000");
  assert.strictEqual(api.normalizeShippingZip("00000-9999"), "00000");
  assert.strictEqual(api.normalizeShippingZip(" A1A 1A1 "), "A1A1A1");
  assert.strictEqual(api.normalizeShippingZip("12"), "");
  assert.strictEqual(api.normalizeShippingZip(""), "");
});

check("index.html includes Claim Your Vault Card section with all 4 steps", function () {
  var html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.ok(html.includes("Claim Your Vault Card 🗝️"), "missing section title");
  assert.ok(html.includes("eBay or Mercari purchase history"), "missing step 1");
  assert.ok(html.includes("Claim My Card"), "missing step 2 / CTA");
  assert.ok(html.includes("order number and the shipping ZIP"), "missing step 3");
  assert.ok(html.includes("lands on your personal page"), "missing step 4");
  assert.ok(html.includes("Each card can be claimed once."), "missing once note");
  assert.ok(!/claim insert in your sleeve/i.test(html), "stale sleeve copy remains");
});

check("vault-app.js uses claim_card_by_order and keeps legacy claim_card_account", function () {
  var src = fs.readFileSync(path.join(__dirname, "../assets/vault-app.js"), "utf8");
  assert.ok(/claim_card_by_order/.test(src), "missing claim_card_by_order RPC call");
  assert.ok(/claim_card_account/.test(src), "missing legacy claim_card_account fallback");
  assert.ok(/shipping_zip/.test(src), "missing shipping_zip payload");
  assert.ok(/Have an older claim code\?/.test(src), "missing legacy code toggle");
});

check("migration defines card_order_zip_keys with RLS and lockout", function () {
  var sql = fs.readFileSync(path.join(__dirname, "../supabase/migrations/20261124213000_order_zip_claim.sql"), "utf8");
  assert.ok(/create table if not exists app_private\.card_order_zip_keys/.test(sql));
  assert.ok(/enable row level security/.test(sql));
  assert.ok(/create or replace function public\.claim_card_by_order/.test(sql));
  assert.ok(/v_user_fails >= 5/.test(sql), "missing lockout threshold");
});

if (fails) {
  console.error(fails + " failed");
  process.exit(1);
}
console.log("all order+zip tests passed");
