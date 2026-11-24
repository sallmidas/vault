/* Fixture-only tests for scan-to-claim URL handling.
   Codes below are fake test values, never live claim codes. */
"use strict";
var assert = require("assert");
var api = require("../assets/vault-claim-link.js");

var FAKE = "VS-2345-67";
var FAKE_COMPACT = "vs234567";
var BAD = "VS-01OL-II";

function mem() {
  var data = {};
  return {
    data: data,
    getItem: function (k) { return Object.prototype.hasOwnProperty.call(data, k) ? data[k] : null; },
    setItem: function (k, v) { data[k] = String(v); },
    removeItem: function (k) { delete data[k]; }
  };
}

var fails = 0;
function check(name, fn) {
  try { fn(); console.log("ok  " + name); }
  catch (e) { fails += 1; console.error("FAIL  " + name + ": " + e.message); }
}

check("normalize compact and dashed fake codes", function () {
  assert.strictEqual(api.normalizeCode(FAKE), FAKE);
  assert.strictEqual(api.normalizeCode(FAKE_COMPACT), FAKE);
  assert.strictEqual(api.normalizeCode("  " + FAKE.toLowerCase() + "  "), FAKE);
  assert.strictEqual(api.normalizeCard("20"), "020");
  assert.strictEqual(api.normalizeCard("020"), "020");
});

check("reject invalid codes and never invent a value", function () {
  assert.strictEqual(api.normalizeCode(BAD), "");
  assert.strictEqual(api.normalizeCode(""), "");
  assert.strictEqual(api.normalizeCode("hello"), "");
  assert.strictEqual(api.normalizeCard("0200"), "");
});

check("strip code, keep card, never leave code in the url", function () {
  var href = "/?card=020&code=" + FAKE + "#x";
  var next = api.stripCodeFromHref(href);
  assert.strictEqual(next, "/?card=020#x");
  assert.ok(next.indexOf("code") === -1);
  assert.ok(next.indexOf(FAKE) === -1);
});

check("strip an invalid code too, so a bad link does not stay in the bar", function () {
  var next = api.stripCodeFromHref("/?card=020&code=" + BAD);
  assert.strictEqual(next, "/?card=020");
  assert.ok(next.indexOf("code") === -1);
});

check("capture and replaceState, stash only a valid card+code pair", function () {
  var store = mem();
  var history = { state: null, href: "/?card=020&code=" + FAKE, replaceState: function (s, t, url) { this.href = url; } };
  var result = api.captureAndStrip({
    search: "?card=020&code=" + FAKE,
    href: history.href,
    history: history,
    storages: [store],
    now: 1000
  });
  assert.strictEqual(result.stripped, true);
  assert.strictEqual(result.hasPending, true);
  assert.strictEqual(result.url, "/?card=020");
  assert.ok(JSON.stringify(result).indexOf(FAKE) === -1, "result must not echo the code");
  assert.strictEqual(history.href, "/?card=020");
  var pending = api.readPending([store], 1000);
  assert.ok(pending);
  assert.strictEqual(pending.card, "020");
  assert.strictEqual(pending.code, FAKE);
});

check("do not stash an invalid code, but still strip it", function () {
  var store = mem();
  var result = api.captureAndStrip({
    search: "?card=020&code=" + BAD,
    href: "/?card=020&code=" + BAD,
    history: { replaceState: function () {} },
    storages: [store],
    now: 1000
  });
  assert.strictEqual(result.stripped, true);
  assert.strictEqual(result.hasPending, false);
  assert.strictEqual(api.readPending([store], 1000), null);
});

check("expired stash is ignored and removed", function () {
  var store = mem();
  api.writePending([store], { card: "020", code: FAKE }, 1);
  assert.strictEqual(api.readPending([store], 1 + api.TTL_MS + 1), null);
  assert.strictEqual(store.getItem(api.STORAGE_KEY), null);
});

check("clearPending removes the stash", function () {
  var store = mem();
  api.writePending([store], { card: "020", code: FAKE }, 1000);
  api.clearPending([store]);
  assert.strictEqual(api.readPending([store], 1000), null);
});

check("captureAndStrip no-ops when there is no code param", function () {
  var store = mem();
  var result = api.captureAndStrip({
    search: "?card=020",
    href: "/?card=020",
    history: { replaceState: function () { throw new Error("should not replace"); } },
    storages: [store],
    now: 1000
  });
  assert.strictEqual(result.stripped, false);
  assert.strictEqual(result.hasPending, false);
  assert.strictEqual(api.readPending([store], 1000), null);
});

if (fails) {
  console.error(fails + " failed");
  process.exit(1);
}
console.log("all tests passed");
