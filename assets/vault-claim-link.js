/* The Vaulted Shelf — capture a scan-to-claim link, then drop the secret
   from the URL immediately so it never stays in history, the address bar,
   or a later sign-in redirect. Manual typing still works in the claim form.
   This file is also loaded by a Node test; it must not print the code. */
(function (root) {
  "use strict";
  var STORAGE_KEY = "vs_pending_claim";
  var TTL_MS = 2 * 60 * 60 * 1000;
  var CODE_BODY_RE = /^[2-9A-HJKMNP-Z]{6}$/;

  function normalizeCard(raw) {
    var d = String(raw == null ? "" : raw).replace(/\D/g, "");
    if (!d || d.length > 3) return "";
    return ("000" + d).slice(-3);
  }

  function normalizeCode(raw) {
    var s = String(raw == null ? "" : raw).toUpperCase().replace(/[^A-Z0-9]/g, "");
    var body = null;
    if (s.length === 8 && s.indexOf("VS") === 0) body = s.slice(2);
    else if (s.length === 6) body = s;
    if (!body || !CODE_BODY_RE.test(body)) return "";
    return "VS-" + body.slice(0, 4) + "-" + body.slice(4);
  }

  function captureFromSearch(search) {
    var params;
    try { params = new URLSearchParams(search || ""); } catch (e) {
      return { card: "", code: "", dirty: false };
    }
    var hadCode = params.has("code");
    var card = normalizeCard(params.get("card") || params.get("claim"));
    var code = hadCode ? normalizeCode(params.get("code")) : "";
    return { card: card, code: code, dirty: hadCode };
  }

  function stripCodeFromHref(href) {
    var path = "/";
    var search = "";
    var hash = "";
    var raw = String(href == null ? "" : href);
    var hashAt = raw.indexOf("#");
    if (hashAt >= 0) { hash = raw.slice(hashAt); raw = raw.slice(0, hashAt); }
    var qAt = raw.indexOf("?");
    if (qAt >= 0) { search = raw.slice(qAt); path = raw.slice(0, qAt) || "/"; }
    else { path = raw || "/"; }
    var params;
    try { params = new URLSearchParams(search); } catch (e) { return path + hash; }
    if (!params.has("code")) return (path || "/") + search + hash;
    params.delete("code");
    var next = params.toString();
    return (path || "/") + (next ? "?" + next : "") + hash;
  }

  function writePending(storages, pending, now) {
    if (!pending || !pending.card || !pending.code) return;
    var payload = JSON.stringify({ card: pending.card, code: pending.code, t: now || Date.now() });
    (storages || []).forEach(function (store) {
      if (!store || typeof store.setItem !== "function") return;
      try { store.setItem(STORAGE_KEY, payload); } catch (e) {}
    });
  }

  function readPending(storages, now) {
    var ts = now || Date.now();
    var found = null;
    (storages || []).forEach(function (store) {
      if (found || !store || typeof store.getItem !== "function") return;
      var raw;
      try { raw = store.getItem(STORAGE_KEY); } catch (e) { return; }
      if (!raw) return;
      var data;
      try { data = JSON.parse(raw); } catch (e) { return; }
      if (!data || !data.card || !data.code || !data.t) return;
      if (ts - data.t > TTL_MS) {
        try { store.removeItem(STORAGE_KEY); } catch (e2) {}
        return;
      }
      var card = normalizeCard(data.card);
      var code = normalizeCode(data.code);
      if (card && code) found = { card: card, code: code, t: data.t };
    });
    return found;
  }

  function clearPending(storages) {
    (storages || []).forEach(function (store) {
      if (!store || typeof store.removeItem !== "function") return;
      try { store.removeItem(STORAGE_KEY); } catch (e) {}
    });
  }

  function defaultStorages() {
    var out = [];
    try { if (root.sessionStorage) out.push(root.sessionStorage); } catch (e) {}
    try { if (root.localStorage) out.push(root.localStorage); } catch (e) {}
    return out;
  }

  function captureAndStrip(opts) {
    opts = opts || {};
    var captured = captureFromSearch(opts.search);
    var nextUrl = captured.dirty ? stripCodeFromHref(opts.href) : opts.href;
    if (captured.dirty && opts.history && typeof opts.history.replaceState === "function") {
      try { opts.history.replaceState(opts.history.state, "", nextUrl); } catch (e) {}
    }
    if (captured.card && captured.code) {
      writePending(opts.storages || [], { card: captured.card, code: captured.code }, opts.now);
    }
    return { stripped: !!captured.dirty, url: nextUrl, hasPending: !!(captured.card && captured.code) };
  }

  function bootFromLocation() {
    if (typeof location === "undefined") return;
    var href = location.pathname + location.search + location.hash;
    captureAndStrip({
      search: location.search,
      href: href,
      history: typeof history !== "undefined" ? history : null,
      storages: defaultStorages(),
      now: Date.now()
    });
  }

  var api = {
    STORAGE_KEY: STORAGE_KEY,
    TTL_MS: TTL_MS,
    normalizeCard: normalizeCard,
    normalizeCode: normalizeCode,
    captureFromSearch: captureFromSearch,
    stripCodeFromHref: stripCodeFromHref,
    writePending: writePending,
    readPending: readPending,
    clearPending: clearPending,
    defaultStorages: defaultStorages,
    captureAndStrip: captureAndStrip,
    bootFromLocation: bootFromLocation
  };

  if (typeof document !== "undefined") {
    try { bootFromLocation(); } catch (e) {}
  }

  root.__vaultClaimLink = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof window !== "undefined" ? window : (typeof globalThis !== "undefined" ? globalThis : this));
