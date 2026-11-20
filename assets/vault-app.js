/* The Vaulted Shelf v2 — accounts, claiming, card pages, wall, videos, My Vault.
   Plain ES5-ish JS, no build step. Talks to Supabase only through the
   publishable key + RPCs; every rule (one claim per card, handle checks,
   puzzle answers) is enforced server-side. */
(function () {
  "use strict";
  var cfg = window.VAULT_CONFIG || {};
  var DATA = window.VAULT_DATA || { cards: {}, videos: {}, videoOrder: [] };
  var BASE = document.body.getAttribute("data-base") || "";
  var PAGE = document.body.getAttribute("data-page") || "home";
  var STORE = BASE + (cfg.storePath || "store/");

  // ---------- utils ----------
  function $(sel, root) { return (root || document).querySelector(sel); }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function normNo(raw) {
    var d = String(raw || "").replace(/\D/g, "");
    if (!d || d.length > 3) return "";
    return ("000" + d).slice(-3);
  }
  function fmtDate(iso) {
    if (!iso) return "";
    try {
      return new Date(iso).toLocaleDateString("en-US", { timeZone: "America/New_York", month: "short", day: "numeric", year: "numeric" });
    } catch (e) { return ""; }
  }
  function prettyDate(value) {
    if (!value) return "";
    if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return fmtDate(value + "T12:00:00-05:00");
    return fmtDate(value) || value;
  }
  function cardMedia(info) {
    var video = null, song = null;
    if (info && info.video) video = typeof info.video === "string" ? DATA.videos[info.video] : info.video;
    if (info && info.song) song = info.song;
    return { video: video || null, song: song || null };
  }
  function cardUrl(no) { return BASE + "?card=" + no; }
  function cardInfo(no) { return DATA.cards[no] || null; }
  function setStatus(el, msg, kind) {
    if (!el) return;
    el.textContent = msg || "";
    el.classList.remove("is-ok", "is-error");
    if (kind) el.classList.add(kind);
  }
  function busy(btn, on, label) {
    if (!btn) return;
    if (on) { btn.dataset.label = btn.textContent; btn.disabled = true; btn.textContent = label || "Working…"; }
    else { btn.disabled = false; if (btn.dataset.label) btn.textContent = btn.dataset.label; }
  }
  function picture(no, side, sizes, cls, alt, eager) {
    var p = BASE + "assets/cards/" + no + "-" + side;
    return '<picture><source type="image/webp" srcset="' + p + '-480.webp 480w, ' + p + '-900.webp 900w" sizes="' + (sizes || "50vw") + '">' +
      '<img src="' + p + '-480.jpg" width="480" height="672" alt="' + esc(alt || "") + '"' + (cls ? ' class="' + cls + '"' : "") +
      (eager ? ' fetchpriority="high"' : ' loading="lazy"') + ' decoding="async"></picture>';
  }
  var VAULT_SVG = '<svg viewBox="0 0 64 64" fill="none" aria-hidden="true"><circle cx="32" cy="32" r="28" stroke="currentColor" stroke-width="2"/><circle cx="32" cy="32" r="19" stroke="currentColor" stroke-width="1.5"/><circle cx="32" cy="32" r="4" fill="currentColor"/><path d="M32 13v10M32 41v10M13 32h10M41 32h10M18.6 18.6l7 7M38.4 38.4l7 7M45.4 18.6l-7 7M25.6 38.4l-7 7" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
  function placeholder(label) { return '<div class="ph-card">' + VAULT_SVG.replace('<svg', '<svg style="display:block"') + '<span>' + esc(label || "Art in the vault") + '</span></div>'; }
  function cardThumb(no, info, sizes) {
    return info && info.art ? picture(no, "front", sizes || "(min-width: 980px) 18vw, (min-width: 640px) 30vw, 46vw", "", "Card No. " + no + " · " + info.name) : placeholder("Art coming");
  }

  // ---------- Supabase ----------
  var sb = null;
  try {
    if (window.supabase && cfg.supabase && cfg.supabase.url) {
      sb = window.supabase.createClient(cfg.supabase.url, cfg.supabase.anonKey, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "implicit" }
      });
    }
  } catch (e) { sb = null; }

  function rpc(name, args) {
    if (!sb) return Promise.reject(new Error("offline"));
    return sb.rpc(name, args || {}).then(function (res) {
      if (res.error) throw res.error;
      return res.data;
    });
  }

  var state = { session: null, profile: undefined, ready: false };
  var listeners = [];
  function onAuth(fn) { listeners.push(fn); if (state.ready) fn(state); }
  function emit() { listeners.forEach(function (fn) { try { fn(state); } catch (e) { console.error(e); } }); }
  function loadProfile() {
    if (!state.session) { state.profile = null; return Promise.resolve(null); }
    return rpc("my_profile").then(function (p) { state.profile = p || null; return state.profile; })
      .catch(function () { state.profile = null; return null; });
  }
  function initAuth() {
    var hashErr = "";
    try {
      var h = new URLSearchParams(location.hash.replace(/^#/, ""));
      if (h.get("error_description")) hashErr = h.get("error_description");
    } catch (e) {}
    state.authError = hashErr;
    if (!sb) { state.ready = true; emit(); return; }
    sb.auth.getSession().then(function (r) {
      state.session = (r && r.data && r.data.session) || null;
      return loadProfile();
    }).then(function () {
      state.ready = true; emit();
      if (location.hash && /access_token|error_description/.test(location.hash)) {
        history.replaceState(null, "", location.pathname + location.search);
      }
    });
    sb.auth.onAuthStateChange(function (event, session) {
      if (!state.ready) return;
      var had = state.session && state.session.user && state.session.user.id;
      var now = session && session.user && session.user.id;
      state.session = session || null;
      if (had !== now) loadProfile().then(emit);
    });
  }
  function signOut() {
    if (!sb) return;
    sb.auth.signOut().then(function () { state.session = null; state.profile = null; emit(); });
  }
  function sendLink(email, redirect) {
    return sb.auth.signInWithOtp({ email: email, options: { emailRedirectTo: redirect, shouldCreateUser: true } })
      .then(function (r) { if (r.error) throw r.error; });
  }
  function verifyCode(email, token) {
    return sb.auth.verifyOtp({ email: email, token: token, type: "email" }).then(function (r) {
      if (r.error) throw r.error;
      state.session = r.data.session; return loadProfile().then(emit);
    });
  }
  function cleanRedirect() { return location.origin + location.pathname + location.search; }

  // ---------- Nav + footer ----------
  var NAV = [
    ["cards", "Vault Cards", BASE + "#cards"],
    ["videos", "Vault Videos", BASE + "videos/"],
    ["wall", "Claimed Wall", BASE + "wall/"],
    ["vault", "My Vault", BASE + "vault/"],
    ["shop", "Shop", STORE]
  ];
  function renderNav() {
    var slot = $("#vnav-slot");
    if (!slot) return;
    var overlay = PAGE === "home" && !document.body.classList.contains("is-card");
    var links = NAV.map(function (n) {
      var cur = n[0] === PAGE ? ' aria-current="page"' : "";
      return '<li><a href="' + n[2] + '"' + cur + '>' + n[1] + '</a></li>';
    }).join("");
    slot.outerHTML =
      '<a class="skip-link" href="#main">Skip to content</a>' +
      '<nav class="vnav' + (overlay ? " is-overlay" : "") + '" aria-label="Main">' +
        '<a class="vnav-brand" href="' + (BASE || "./") + '">' + VAULT_SVG + '<span>The Vaulted Shelf</span></a>' +
        '<ul class="vnav-links">' + links + '</ul>' +
        '<a class="vnav-account" id="vnav-account" href="' + BASE + 'vault/">Sign in</a>' +
        '<button class="vnav-menu" type="button" aria-expanded="false" aria-controls="vnav-drawer" aria-label="Menu">' +
          '<svg viewBox="0 0 24 24" fill="none"><path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg></button>' +
      '</nav>' +
      '<div class="vnav-drawer" id="vnav-drawer" hidden>' + NAV.map(function (n) {
        return '<a href="' + n[2] + '"' + (n[0] === PAGE ? ' aria-current="page"' : "") + '>' + n[1] + '</a>';
      }).join("") + '</div>';
    var btn = $(".vnav-menu"), drawer = $("#vnav-drawer");
    btn.addEventListener("click", function () {
      var open = drawer.hidden; drawer.hidden = !open; btn.setAttribute("aria-expanded", String(open));
    });
    drawer.addEventListener("click", function (e) { if (e.target.tagName === "A") { drawer.hidden = true; btn.setAttribute("aria-expanded", "false"); } });
    if (overlay) {
      var nav = $(".vnav");
      var onScroll = function () { nav.classList.toggle("is-scrolled", window.scrollY > 40); };
      window.addEventListener("scroll", onScroll, { passive: true }); onScroll();
    }
    onAuth(function (s) {
      var a = $("#vnav-account");
      if (!a) return;
      if (s.session && s.profile && s.profile.handle) a.textContent = "@" + s.profile.handle;
      else if (s.session) a.textContent = "My Vault";
      else a.textContent = "Sign in";
    });
  }
  function renderFooter() {
    var slot = $("#vfoot-slot");
    if (!slot) return;
    slot.outerHTML = '<footer class="vfoot"><nav aria-label="Footer">' + NAV.map(function (n) {
      return '<a href="' + n[2] + '">' + n[1] + '</a>';
    }).join("") + '</nav><p>The Vaulted Shelf · One Key · One Vault</p>' +
      '<p class="tiny">Not affiliated with or endorsed by Funko or any rights holder.</p>' +
      '<p class="forged-badge">Forged with <b>Ace</b> · 2026</p></footer>';
  }

  // ---------- Claim flow (used on card pages and My Vault) ----------
  // Renders the right step for the current account into `box`.
  function claimFlow(box, opts) {
    opts = opts || {};
    var cardNo = opts.cardNo || "";
    function render(s) {
      if (!sb) { box.innerHTML = '<p class="vstatus is-error">The vault is offline right now. Please try again soon.</p>'; return; }
      if (!s.session) return renderSignIn(box, { title: opts.signInTitle || "Sign in to claim", note: opts.signInNote, after: opts.signInAfter, step4: opts.signInStep4 });
      if (!s.profile || !s.profile.handle) return renderHandle(box, { onDone: function () { render(state); } });
      renderClaimForm(box, cardNo, opts);
    }
    onAuth(render);
  }

  function renderSignIn(box, o) {
    o = o || {};
    box.innerHTML =
      '<h2>' + esc(o.title || "Sign in") + '</h2>' +
      '<p>' + esc(o.note || "No password. We email you a one-tap sign-in link.") + '</p>' +
      (state.authError ? '<p class="vstatus is-error">That sign-in link expired or was already used. Send a new one below.</p>' : "") +
      '<form class="vform" novalidate data-k="signin">' +
        '<div class="vfield"><label for="si-email">Email</label><input id="si-email" type="email" inputmode="email" autocomplete="email" required placeholder="you@email.com"></div>' +
        '<button class="btn btn-primary" type="submit">Email my sign-in link</button>' +
        '<p class="vstatus" role="status" aria-live="polite"></p>' +
      '</form>' +
      '<div data-k="code" hidden><form class="vform" novalidate>' +
        '<div class="vfield"><label for="si-code">6-digit code from the email</label><input id="si-code" inputmode="numeric" autocomplete="one-time-code" maxlength="10" placeholder="123456"></div>' +
        '<button class="btn btn-ghost" type="submit">Sign in with code</button>' +
        '<p class="vstatus" role="status" aria-live="polite"></p></form></div>' +
      '<ol class="signin-steps"><li>Enter your email.</li><li>Open the link we send (check spam).</li><li>Pick your collector handle.</li><li>' + esc(o.step4 || "Enter the claim code from your insert.") + '</li></ol>' +
      (o.after ? '<p class="tiny signin-after">' + esc(o.after) + '</p>' : "");
    var f = $('form[data-k="signin"]', box), st = $(".vstatus", f), btn = $("button", f);
    var codeWrap = $('[data-k="code"]', box);
    var lastEmail = "";
    f.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = $("#si-email", box).value.trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { setStatus(st, "Please enter a valid email address.", "is-error"); $("#si-email", box).focus(); return; }
      busy(btn, true, "Sending…"); setStatus(st, "");
      sendLink(email, cleanRedirect()).then(function () {
        lastEmail = email;
        busy(btn, false); btn.textContent = "Send again";
        setStatus(st, "Check " + email + " for your sign-in link. It works for 1 hour.", "is-ok");
        codeWrap.hidden = false;
      }).catch(function (err) {
        busy(btn, false);
        var m = String((err && err.message) || "");
        setStatus(st, /rate|seconds|security purposes/i.test(m) ? "Please wait a minute before asking for another link." : "We couldn't send that link. Please try again in a moment.", "is-error");
      });
    });
    var cf = $("form", codeWrap), cst = $(".vstatus", cf), cbtn = $("button", cf);
    cf.addEventListener("submit", function (e) {
      e.preventDefault();
      var code = $("#si-code", box).value.replace(/\D/g, "");
      if (code.length < 6) { setStatus(cst, "Enter the code from the email.", "is-error"); return; }
      busy(cbtn, true, "Checking…");
      verifyCode(lastEmail, code).catch(function () { busy(cbtn, false); setStatus(cst, "That code didn't work. Use the link in the email instead.", "is-error"); });
    });
  }

  function renderHandle(box, o) {
    o = o || {};
    var current = (state.profile && state.profile.handle) || "";
    box.innerHTML =
      '<h2>' + (current ? "Change your handle" : "Pick your collector handle") + '</h2>' +
      '<p>This is how the vault credits you: <strong>Claimed by @you</strong> on card pages, the wall, and vault videos.</p>' +
      '<form class="vform" novalidate>' +
        '<div class="vfield"><label for="h-in">Handle</label><div class="handle-input"><span aria-hidden="true">@</span>' +
        '<input id="h-in" autocomplete="nickname" autocapitalize="off" spellcheck="false" maxlength="20" pattern="[A-Za-z0-9_]{3,20}" required value="' + esc(current) + '" aria-describedby="h-help"></div>' +
        '<p class="help" id="h-help">3–20 letters, numbers or underscores. Shown publicly.</p></div>' +
        '<button class="btn btn-primary" type="submit">' + (current ? "Save handle" : "Claim my handle") + '</button>' +
        (current ? '<button class="linkish" type="button" data-k="cancel">Cancel</button>' : "") +
        '<p class="vstatus" role="status" aria-live="polite"></p>' +
      '</form>';
    var f = $("form", box), st = $(".vstatus", f), btn = $('button[type="submit"]', f), inp = $("#h-in", box);
    var t = 0;
    inp.addEventListener("input", function () {
      clearTimeout(t);
      var v = inp.value.trim();
      if (!/^[A-Za-z0-9_]{3,20}$/.test(v)) { setStatus(st, v ? "3–20 letters, numbers or underscores." : "", v ? "is-error" : ""); return; }
      t = setTimeout(function () {
        rpc("check_handle", { handle: v }).then(function (r) {
          if (inp.value.trim() !== v) return;
          if (r && r.ok) setStatus(st, "@" + v + " is available.", "is-ok");
          else setStatus(st, r && r.error === "taken" ? "That handle is taken." : "That handle isn't allowed. Try another.", "is-error");
        }).catch(function () {});
      }, 350);
    });
    var cancel = $('[data-k="cancel"]', f);
    if (cancel) cancel.addEventListener("click", function () { if (o.onDone) o.onDone(); });
    f.addEventListener("submit", function (e) {
      e.preventDefault();
      var v = inp.value.trim();
      if (!/^[A-Za-z0-9_]{3,20}$/.test(v)) { setStatus(st, "Use 3–20 letters, numbers or underscores.", "is-error"); inp.focus(); return; }
      busy(btn, true, "Saving…");
      rpc("set_handle", { handle: v }).then(function (r) {
        busy(btn, false);
        if (r && r.ok) { state.profile = { handle: r.handle }; emit(); if (o.onDone) o.onDone(); }
        else setStatus(st, (r && r.message) || "That handle isn't available.", "is-error");
      }).catch(function () { busy(btn, false); setStatus(st, "That didn't go through. Please try again.", "is-error"); });
    });
  }

  function renderClaimForm(box, cardNo, opts) {
    var info = cardNo ? cardInfo(cardNo) : null;
    var founder = !!(opts && opts.founder);
    var mode = "code";
    box.innerHTML =
      '<h2>' + (founder ? "Founder claim · No. " + cardNo : cardNo ? "Claim Card No. " + cardNo : "Claim a card") + '</h2>' +
      '<p class="c-intro"></p>' +
      '<form class="vform" novalidate>' +
        (cardNo ? "" : '<div class="vfield"><label for="c-no">Card number</label><input id="c-no" inputmode="numeric" maxlength="3" placeholder="013" required value="' + esc(opts.prefill || "") + '"></div>') +
        '<div class="vfield"><label for="c-key" id="c-key-label">Claim code</label>' +
        '<input id="c-key" class="code-input" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="24" required aria-describedby="c-key-help">' +
        '<p class="help" id="c-key-help"></p></div>' +
        (founder ? "" : '<button class="linkish c-switch" type="button" aria-controls="c-key"></button>') +
        '<p class="help">Claiming as <strong>@' + esc(state.profile.handle) + '</strong>. One card, one collector, forever.</p>' +
        '<button class="btn btn-primary" type="submit">' + (founder ? "Make the Founder claim" : "Claim" + (info ? " " + esc(info.name) : " this card")) + '</button>' +
        '<p class="vstatus" role="status" aria-live="polite"></p>' +
      '</form>';
    var f = $("form", box), st = $(".vstatus", f), btn = $('button[type="submit"]', f);
    var inp = $("#c-key", box), lab = $("#c-key-label", box), help = $("#c-key-help", box), intro = $(".c-intro", box), sw = $(".c-switch", box);
    function setMode(m) {
      mode = m;
      setStatus(st, "", "");
      inp.value = "";
      if (m === "code") {
        lab.textContent = founder ? "Founder code" : "Claim code";
        inp.placeholder = "VS-XXXX-XX"; inp.setAttribute("inputmode", "text"); inp.setAttribute("autocapitalize", "characters");
        help.textContent = founder ? "The private Founder code held by The Vaulted Shelf." : "Under the scratch-off on the claim insert that came with your card.";
        intro.textContent = founder
          ? "This Founder's card is reserved. It's claimed once, with the private Founder code."
          : "Your private claim code is the key. It's on the sealed insert in your card sleeve, never on the card or in any photo. We check it privately.";
        if (sw) sw.textContent = "No claim code? Use your eBay order number";
      } else {
        lab.textContent = "eBay order number";
        inp.placeholder = "12-34567-89012"; inp.setAttribute("inputmode", "numeric"); inp.removeAttribute("autocapitalize");
        help.textContent = "For cards that shipped before claim codes. Find it in your eBay purchase history.";
        intro.textContent = "No insert in your sleeve? Cards that shipped before claim codes unlock with the eBay order number. We check it privately and never show it to anyone.";
        if (sw) sw.textContent = "Have a claim code? Use it instead";
      }
    }
    // Cards that shipped before claim inserts (003–005) open on the order-number path.
    setMode(!founder && info && info.orderKey ? "order" : "code");
    if (sw) sw.addEventListener("click", function () { setMode(mode === "code" ? "order" : "code"); inp.focus(); });
    // Codes are VS + 6 characters. Normalize by length so a code whose body starts with "VS" still works.
    function tidyCode() {
      if (mode !== "code") return;
      var raw = inp.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
      var body = raw.length === 8 && raw.indexOf("VS") === 0 ? raw.slice(2) : raw.length === 6 ? raw : null;
      if (body) inp.value = "VS-" + body.slice(0, 4) + "-" + body.slice(4);
    }
    inp.addEventListener("input", function () {
      if (st.textContent) setStatus(st, "", "");
      if (mode !== "code") return;
      var up = inp.value.toUpperCase();
      if (up !== inp.value) { var pos = inp.selectionStart; inp.value = up; try { inp.setSelectionRange(pos, pos); } catch (e) {} }
    });
    inp.addEventListener("blur", tidyCode);
    f.addEventListener("submit", function (e) {
      e.preventDefault();
      var no = cardNo || normNo($("#c-no", box).value);
      tidyCode();
      var key = inp.value.trim();
      if (!no) { setStatus(st, "Enter the 3-digit card number.", "is-error"); return; }
      if (mode === "code" && !/^VS-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{2}$/.test(key)) {
        setStatus(st, /[01OIL]/.test(key.replace(/^VS-?/, "")) ? "Claim codes never use 0, O, 1, I or L. Check the letters on your insert." : "Enter the full code, like VS-XXXX-XX.", "is-error"); inp.focus(); return;
      }
      if (mode === "order" && key.replace(/\D/g, "").length < 8) { setStatus(st, "Enter your full eBay order number.", "is-error"); inp.focus(); return; }
      busy(btn, true, "Unlocking…");
      rpc("claim_card_account", { card_no: no, order_key: key }).then(function (r) {
        busy(btn, false);
        if (r && r.ok) {
          setStatus(st, r.already_mine ? "This card is already in your vault." : "Unlocked. Card No. " + no + " is yours.", "is-ok");
          var done = function () { if (opts.onClaimed) opts.onClaimed(r); };
          if (!r.already_mine && typeof window.__vaultPlayReveal === "function") window.__vaultPlayReveal(no, "@" + r.handle, done);
          else done();
        } else {
          setStatus(st, (r && r.message) || "Unable to claim this card.", "is-error");
          if (r && r.error === "no_handle") { state.profile = null; emit(); }
        }
      }).catch(function () { busy(btn, false); setStatus(st, "That didn't go through. Please try again in a moment.", "is-error"); });
    });
  }

  // ---------- Card page (index.html?card=00X) ----------
  function renderCardPage(no) {
    var root = $("#card-page");
    if (!root) return;
    root.hidden = false;
    var info = cardInfo(no);
    var nums = Object.keys(DATA.cards).sort();
    var idx = nums.indexOf(no);
    var prev = idx > 0 ? nums[idx - 1] : null, next = idx >= 0 && idx < nums.length - 1 ? nums[idx + 1] : null;
    var title = info ? info.name : "Card No. " + no;
    document.title = "No. " + no + (info ? " · " + info.name : "") + " · The Vaulted Shelf";

    var reveal = info && info.reveal && cfg.reveals && cfg.reveals[info.reveal];
    var media = cardMedia(info);
    var video = media.video;
    var song = media.song;
    var dates = [];
    if (info && info.sold) dates.push("<span>Sold</span> " + esc(prettyDate(info.sold)));
    if (info && info.shipped) dates.push("<span>Shipped</span> " + esc(prettyDate(info.shipped)));
    // Multi-part story sets (e.g. 017): same front, one back per part ("back", "back2", ...).
    var parts = (info && info.story && Array.isArray(info.story.parts)) ? info.story.parts : [];
    var art = info && info.art
      ? '<div class="flip" id="flip"><div class="flip-inner">' +
          '<div class="flip-face front">' + picture(no, "front", "(min-width: 900px) 26rem, 92vw", "", "Card No. " + no + " front", true) + '</div>' +
          '<div class="flip-face back">' + picture(no, parts.length ? (parts[0].side || "back") : "back", "(min-width: 900px) 26rem, 92vw", "", "Card No. " + no + " back") + '</div>' +
          '<button class="flip-btn" type="button" aria-label="Flip card"></button></div></div>' +
        '<div class="flip-controls"><div class="seg" role="group" aria-label="Card side"><button type="button" data-side="front" aria-pressed="true">Front</button>' +
          (parts.length > 1
            ? parts.map(function (pt, i) { return '<button type="button" data-side="back" data-part="' + i + '" aria-pressed="false">' + esc(pt.label) + '</button>'; }).join("")
            : '<button type="button" data-side="back" aria-pressed="false">Back</button>') +
        '</div></div>' +
        '<p class="flip-hint">' + (parts.length > 1 ? "Two cards, one story. Tap the card to flip it." : "Tap the card to flip it.") + '</p>'
      : '<div class="flip"><div class="flip-inner"><div class="flip-face">' + placeholder(info ? "Card art is being forged" : "Not in the registry yet") + '</div></div></div>';

    var storyHtml = parts.length > 1
      ? '<section class="vpanel story-panel" aria-labelledby="cp-story"><h2 id="cp-story">' + esc(info.story.title || "The story") + '</h2>' +
          (info.story.intro ? '<p class="tiny">' + esc(info.story.intro) + '</p>' : "") +
          '<ol class="story-parts">' + parts.map(function (pt, i) {
            return '<li><button type="button" class="story-part" data-part="' + i + '" aria-label="Show ' + esc(pt.label) + ' on the card">' +
              '<span class="sp-thumb"><img src="' + BASE + 'assets/cards/' + no + '-' + esc(pt.side) + '-480.jpg" alt="" loading="lazy" decoding="async" width="480" height="672"></span>' +
              '<span class="sp-text"><small>' + esc(pt.label) + ' of ' + parts.length + '</small><b>' + esc(pt.title || "") + '</b><span>' + esc(pt.caption || "") + '</span></span></button></li>';
          }).join("") + '</ol></section>'
      : "";
    var sp = info && info.songPending;
    var songPendingHtml = sp && !song && !video
      ? '<section class="vpanel song-pending" aria-labelledby="cp-sp"><div class="sp-head"><h2 id="cp-sp">Original song</h2><span class="soon-pill">Coming soon</span></div>' +
          '<p class="sp-title"><b>' + esc(sp.title) + '</b>' + (sp.artist ? ' <span>by ' + esc(sp.artist) + '</span>' : "") + '</p>' +
          (sp.blurb ? '<p class="tiny">' + esc(sp.blurb) + '</p>' : "") +
          (sp.hook && sp.hook.length ? '<blockquote class="sp-hook">' + sp.hook.map(esc).join("<br>") + '</blockquote>' : "") +
          '<p class="tiny sp-note">' + esc(sp.note || "Still in the studio. It will play right here when it drops.") + '</p></section>'
      : "";

    root.innerHTML =
      '<div class="cp-head">' +
        '<span class="cp-no">Vault Collector Card · No. ' + no + '</span>' +
        '<h1>' + esc(title) + '</h1>' +
        (info ? '<p class="cp-sub">' + esc([info.line, info.pop, info.tier].filter(Boolean).join(" · ")) + '</p>' : "") +
        (info && info.note ? '<p class="tiny" style="margin-top:.3rem">' + esc(info.note) + '</p>' : "") +
        (dates.length ? '<ul class="cp-dates">' + dates.map(function (x) { return "<li>" + x + "</li>"; }).join("") + "</ul>" : "") +
        '<p class="claim-badge" id="cp-badge" aria-live="polite">Checking the vault…</p>' +
      '</div>' +
      '<div class="cp-grid">' +
        '<div class="cp-art">' + art + '</div>' +
        '<div class="cp-side">' +
          '<section class="vpanel" id="cp-claim" aria-label="Claim this card" hidden></section>' +
          (reveal ? '<section class="vpanel" aria-labelledby="cp-rv"><h2 id="cp-rv">Character reveal</h2><div class="media portrait" style="margin-top:.6rem">' + videoCover(reveal.mp4, reveal.poster.replace(/\.jpg$/, ".webp"), "Play the " + title + " reveal", null, reveal.webm) + '</div></section>' : "") +
          (video ? '<section class="vpanel" aria-labelledby="cp-mv"><h2 id="cp-mv">Music video</h2><div class="media portrait" style="margin-top:.6rem">' + videoCover(video.src, video.poster, "Play the " + (video.title || title) + " music video", video.duration) + '</div></section>' : "") +
          (song ? '<section class="vpanel" aria-labelledby="cp-song"><h2 id="cp-song">' + esc(song.title || "Song") + '</h2><audio class="vault-audio" controls preload="none" src="' + esc(song.src) + '"' + (song.type ? ' type="' + esc(song.type) + '"' : "") + '></audio></section>' : "") +
          storyHtml + songPendingHtml +
          '<section class="vpanel teaser-soon" aria-labelledby="cp-soon"><h2 id="cp-soon">Coming soon from the Vault</h2><p>More collector cards, original videos, and keys to the Founder\'s Collection. Watch this space.</p></section>' +
          '<a class="btn btn-primary" href="' + STORE + '" rel="noopener">Shop on eBay</a>' +
          '<div class="cp-nav">' +
            (prev ? '<a class="btn btn-ghost btn-sm" href="' + cardUrl(prev) + '">← No. ' + prev + '</a>' : "<span></span>") +
            (next ? '<a class="btn btn-ghost btn-sm" href="' + cardUrl(next) + '">No. ' + next + ' →</a>' : "<span></span>") +
          '</div>' +
        '</div>' +
      '</div>';

    wireFlip(root, no, parts);
    wireVideoCovers(root);

    var badge = $("#cp-badge", root), claimBox = $("#cp-claim", root);
    function paint(d) {
      if (!d || d.found !== true) {
        badge.className = "claim-badge";
        badge.textContent = info ? "Unclaimed — waiting in the vault" : "Not in the vault registry yet";
        claimBox.hidden = true;
        return;
      }
      if (d.claimed) {
        badge.className = "claim-badge is-claimed" + (d.is_mine ? " is-mine" : "");
        badge.innerHTML = VAULT_SVG + '<span>Claimed by ' + (d.handle ? "@" : "") + esc(d.display_name || "a collector") + '</span>';
        if (d.is_mine) {
          claimBox.hidden = false;
          claimBox.innerHTML = '<h2>It\'s in your vault</h2><p>Claimed ' + esc(fmtDate(d.claimed_at)) + '. See every card you hold in My Vault.</p><a class="btn btn-ghost" style="margin-top:.8rem" href="' + BASE + 'vault/">Open My Vault</a>';
        } else {
          claimBox.hidden = true;
        }
        return;
      }
      var founder = d.awaits_founder === true;
      badge.className = "claim-badge" + (founder ? " is-founder" : "");
      badge.innerHTML = VAULT_SVG + "<span>" + (founder ? "Unclaimed — awaiting the Founder claim" : "Unclaimed — waiting in the vault") + "</span>";
      claimBox.hidden = false;
      var orderKey = !founder && info && info.orderKey;
      claimFlow(claimBox, { cardNo: no, founder: founder,
        signInNote: founder ? "This Founder's card is reserved for the Founder claim. It unlocks once, with the private Founder code."
                  : orderKey ? "Your order number is your key. Sign in with your email, pick a handle, then enter the eBay order number from your purchase to unlock this card."
                            : "Got this card? Sign in with your email, pick a handle, and unlock it with the claim code from your insert.",
        signInStep4: founder ? "Enter the private Founder code." : orderKey ? "Enter your eBay order number." : "Enter the claim code from your insert.",
        signInAfter: orderKey ? "The order-number box appears right after you sign in. Find the number in your eBay purchase history. We check it privately and never show it." : "",
        onClaimed: load });
    }
    function load() {
      rpc("card_page", { card_no: no }).then(paint).catch(function () {
        badge.className = "claim-badge"; badge.textContent = "We couldn't reach the vault. Try again soon.";
      });
    }
    load();
  }

  function videoCover(src, poster, label, dur, webm) {
    return '<button class="play-cover" type="button" data-src="' + esc(BASE + src) + '"' + (webm ? ' data-webm="' + esc(BASE + webm) + '"' : "") + ' data-poster="' + esc(BASE + poster) + '" aria-label="' + esc(label) + '">' +
      '<img src="' + esc(BASE + poster) + '" alt="" loading="lazy" decoding="async">' +
      '<span class="pbtn"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 4.5v15l13-7.5z"/></svg></span>' +
      (dur ? '<span class="dur">' + esc(dur) + '</span>' : "") + '</button>';
  }
  function wireVideoCovers(root) {
    root.querySelectorAll(".play-cover").forEach(function (b) {
      b.addEventListener("click", function () {
        var v = document.createElement("video");
        v.controls = true; v.playsInline = true; v.setAttribute("playsinline", ""); v.preload = "auto"; v.poster = b.dataset.poster;
        if (b.dataset.webm) { var s1 = document.createElement("source"); s1.src = b.dataset.webm; s1.type = "video/webm"; v.appendChild(s1); }
        var s2 = document.createElement("source"); s2.src = b.dataset.src; s2.type = "video/mp4"; v.appendChild(s2);
        b.replaceWith(v);
        var p = v.play(); if (p && p.catch) p.catch(function () {});
        v.focus();
      });
    });
  }
  function wireFlip(root, no, parts) {
    var flip = $("#flip", root);
    if (!flip) return;
    parts = parts || [];
    var btns = root.querySelectorAll(".seg button");
    var backFace = $(".flip-face.back", flip), part = 0;
    function showPart(i) {
      if (!parts.length || i === part || !parts[i]) return;
      part = i;
      backFace.innerHTML = picture(no, parts[i].side || "back", "(min-width: 900px) 26rem, 92vw", "", "Card No. " + no + " back, " + parts[i].label);
    }
    function set(side) {
      flip.classList.toggle("is-back", side === "back");
      btns.forEach(function (b) {
        var on = b.dataset.side === side && (side !== "back" || b.dataset.part === undefined || +b.dataset.part === part);
        b.setAttribute("aria-pressed", String(on));
      });
      root.querySelectorAll(".story-part").forEach(function (b) { b.classList.toggle("is-on", side === "back" && +b.dataset.part === part); });
    }
    $(".flip-btn", flip).addEventListener("click", function () { set(flip.classList.contains("is-back") ? "front" : "back"); });
    btns.forEach(function (b) { b.addEventListener("click", function () { if (b.dataset.part !== undefined) showPart(+b.dataset.part); set(b.dataset.side); }); });
    root.querySelectorAll(".story-part").forEach(function (b) {
      b.addEventListener("click", function () {
        showPart(+b.dataset.part); set("back");
        if (window.matchMedia("(max-width: 899px)").matches) flip.scrollIntoView({ behavior: "smooth", block: "center" });
      });
    });
  }

  // ---------- Home gallery ----------
  var wallCache = null;
  function getWall() {
    if (!wallCache) wallCache = rpc("claimed_wall").catch(function () { return null; });
    return wallCache;
  }
  function renderGallery() {
    var list = $("#card-grid");
    if (!list) return;
    var nums = Object.keys(DATA.cards).sort();
    list.innerHTML = nums.map(function (no) {
      var c = DATA.cards[no];
      return '<li class="ctile"><a href="' + cardUrl(no) + '"><div class="thumb">' + cardThumb(no, c) + '</div>' +
        '<div class="meta"><div class="no">No. ' + no + ' · ' + esc(c.tier) + '</div><div class="nm">' + esc(c.name) + '</div>' +
        '<div class="st" data-no="' + no + '">Waiting in the vault</div></div></a></li>';
    }).join("");
    getWall().then(function (w) {
      if (!w) return;
      (w.claims || []).forEach(function (c) {
        var el = list.querySelector('.st[data-no="' + c.card_no + '"]');
        if (el) { el.textContent = "Claimed by " + (c.is_handle ? "@" : "") + c.name; el.classList.add("is-claimed"); }
      });
    });
  }

  // ---------- Wall ----------
  function renderWall() {
    var root = $("#wall");
    if (!root) return;
    getWall().then(function (w) {
      if (!w) { root.innerHTML = '<p class="empty-state">We couldn\'t reach the vault. Please try again soon.</p>'; return; }
      var claimed = w.claims || [], leaders = w.leaders || [];
      var claimedSet = {}; claimed.forEach(function (c) { claimedSet[c.card_no] = 1; });
      var waiting = Object.keys(DATA.cards).sort().filter(function (n) { return !claimedSet[n]; });
      root.innerHTML =
        '<div class="stats"><div class="stat"><b>' + (w.claimed || 0) + '</b><span>Claimed</span></div>' +
        '<div class="stat"><b>' + leaders.length + '</b><span>Collectors</span></div>' +
        '<div class="stat"><b>' + Math.max(0, (w.registered || 0) - (w.claimed || 0)) + '</b><span>In the vault</span></div></div>' +
        '<div class="wall-cols"><section aria-labelledby="w-recent"><h2 class="section-title" id="w-recent">Claimed by</h2>' +
        (claimed.length ? '<ul class="wall-list">' + claimed.map(function (c) {
          var info = cardInfo(c.card_no);
          return '<li><a class="wall-item" href="' + cardUrl(c.card_no) + '">' + (info && info.art ? picture(c.card_no, "front", "58px", "", "") : '<span class="ph"></span>') +
            '<span><span class="who">' + (c.is_handle ? "@" : "") + esc(c.name) + '</span><br><span class="what">No. ' + esc(c.card_no) + ' · ' + esc(c.character) + '</span><br><span class="when">' + esc(fmtDate(c.claimed_at)) + '</span></span></a></li>';
        }).join("") + '</ul>' : '<div class="empty-state"><strong>The wall is waiting</strong>No cards have been claimed yet. Got one? <a href="' + BASE + 'vault/">Claim it in My Vault</a>.</div>') +
        '</section><section aria-labelledby="w-lb"><h2 class="section-title" id="w-lb">Top collectors</h2>' +
        (leaders.length ? '<ol class="lb-list">' + leaders.map(function (l, i) {
          return '<li class="lb-item"><span class="lb-rank">' + (i + 1) + '</span><span>' + (l.is_handle ? "@" : "") + esc(l.name) + '<br><span class="tiny">since ' + esc(fmtDate(l.first_claim)) + '</span></span><span class="lb-count">' + l.cards + '</span></li>';
        }).join("") + '</ol>' : '<div class="empty-state"><strong>First spot is open</strong>The first collector to claim a card takes No. 1.</div>') +
        '<h2 class="section-title">Waiting in the vault</h2><ul class="cgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">' + waiting.map(function (n) {
          var c = DATA.cards[n];
          return '<li class="ctile"><a href="' + cardUrl(n) + '"><div class="thumb">' + cardThumb(n, c, "(min-width: 900px) 9rem, 30vw") + '</div><div class="meta"><div class="no">No. ' + n + '</div><div class="nm" style="font-size:.78rem">' + esc(c.name) + '</div></div></a></li>';
        }).join("") + '</ul></section></div>';
    });
  }

  // ---------- Videos ----------
  function renderVideos() {
    var root = $("#videos");
    if (!root) return;
    root.innerHTML = (DATA.videoOrder || []).map(function (id) {
      var v = DATA.videos[id];
      var c = v.card ? cardInfo(v.card) : null;
      return '<article class="vcard" id="v-' + id + '"><div class="media portrait">' + videoCover(v.src, v.poster, "Play " + v.title, v.duration) + '</div>' +
        '<div class="vmeta"><h3>' + esc(v.title) + '</h3><p class="vsub">' + esc(v.sub) + '</p>' +
        (c ? '<p class="vlinks"><a href="' + cardUrl(v.card) + '">Vault Collector Card No. ' + v.card + '</a></p><span class="claimed-tag" data-no="' + v.card + '">Unclaimed — waiting in the vault</span>' : '<p class="vlinks"><a href="' + STORE + '">Find it in the shop</a></p>') +
        '</div></article>';
    }).join("");
    wireVideoCovers(root);
    getWall().then(function (w) {
      if (!w) return;
      (w.claims || []).forEach(function (c) {
        root.querySelectorAll('.claimed-tag[data-no="' + c.card_no + '"]').forEach(function (el) { el.textContent = "Claimed by " + (c.is_handle ? "@" : "") + c.name; });
      });
    });
  }

  // ---------- My Vault ----------
  function renderMyVault() {
    var root = $("#myvault");
    if (!root) return;
    var params = new URLSearchParams(location.search);
    var prefill = normNo(params.get("claim") || params.get("card"));
    onAuth(function (s) {
      if (!sb) { root.innerHTML = '<div class="vpanel"><p class="vstatus is-error">The vault is offline right now. Please try again soon.</p></div>'; return; }
      if (!s.session) {
        root.innerHTML = '<section class="vpanel" id="mv-signin"></section>' +
          '<section class="vpanel"><h2>What you get</h2><p>Your own collector handle, every card you claim in one place, your Founder\'s Collection status, and progress on the crack-the-code puzzle.</p></section>';
        renderSignIn($("#mv-signin"), { title: "Open your vault", note: "Sign in with just your email. We send a one-tap link, no password." });
        return;
      }
      if (!s.profile || !s.profile.handle) {
        root.innerHTML = '<section class="vpanel" id="mv-handle"></section>';
        renderHandle($("#mv-handle"));
        return;
      }
      root.innerHTML = '<p class="vstatus" role="status">Opening your vault…</p>';
      rpc("my_vault").then(function (v) { paintVault(root, v, prefill); })
        .catch(function () { root.innerHTML = '<div class="vpanel"><p class="vstatus is-error">We couldn\'t open your vault. Please refresh.</p></div>'; });
    });
  }
  function paintVault(root, v, prefill) {
    var cards = v.cards || [], pz = v.puzzle || { total: 0, found: 0 }, fs = v.founders_spots || [];
    var pct = pz.total ? Math.round(100 * pz.found / pz.total) : 0;
    var foundSet = {}; (pz.discoveries || []).forEach(function (d) { foundSet[d.card_no] = 1; });
    root.innerHTML =
      '<section class="vpanel"><div class="mv-id"><span class="mv-avatar" aria-hidden="true">' + esc(v.handle.charAt(0).toUpperCase()) + '</span>' +
        '<div><div class="mv-handle">@' + esc(v.handle) + '</div><div class="tiny">Collector since ' + esc(fmtDate(v.member_since)) + '</div></div></div>' +
        '<div class="mv-chips"><span class="chip"><b>' + cards.length + '</b> card' + (cards.length === 1 ? "" : "s") + ' claimed</span>' +
        '<span class="chip">Founder\'s Series: <b>' + (fs.length ? fs.map(function (f) { return "No. " + f.series_no; }).join(", ") : "—") + '</b></span>' +
        '<span class="chip">Code: <b>' + pz.found + "/" + pz.total + '</b></span></div>' +
        '<div class="row" style="margin-top:.9rem"><button class="linkish" type="button" data-k="edit">Change handle</button><button class="linkish" type="button" data-k="out">Sign out</button></div>' +
      '</section>' +
      '<section aria-labelledby="mv-cards"><h2 class="section-title" id="mv-cards">My cards</h2>' +
        (cards.length ? '<ul class="cgrid">' + cards.map(function (c) {
          var info = cardInfo(c.card_no);
          return '<li class="ctile"><a href="' + cardUrl(c.card_no) + '"><div class="thumb">' + cardThumb(c.card_no, info) + '</div><div class="meta"><div class="no">No. ' + esc(c.card_no) + '</div><div class="nm">' + esc(c.character) + '</div><div class="st is-claimed">Claimed ' + esc(fmtDate(c.claimed_at)) + '</div></div></a></li>';
        }).join("") + '</ul>' : '<div class="empty-state"><strong>Your vault is empty</strong>Claim your first card below with the code from your claim insert.</div>') +
      '</section>' +
      '<section class="vpanel" id="mv-claim" style="margin-top:1.2rem"></section>' +
      '<section class="vpanel" aria-labelledby="mv-founder"><h2 id="mv-founder">Founder\'s Collection</h2>' +
        (fs.length ? '<p>You hold Founder\'s Series ' + fs.map(function (f) { return "No. " + f.series_no + " (card " + esc(f.card_no) + ")"; }).join(", ") + '.</p>'
                   : '<p>Every claimed card is your ticket to the Founder\'s Collection, a premium run of about 100. Upgrades open within a year of your order. Watch for the drop on the shop.</p>') +
        '<a class="btn btn-ghost btn-sm" style="margin-top:.8rem;display:inline-flex" href="' + STORE + '">Visit the shop</a></section>' +
      '<section class="vpanel" aria-labelledby="mv-code"><h2 id="mv-code">Crack the code</h2>' +
        (pz.total ? '<p>Hidden symbols are carved into the vault doors. Find them, name them, and unlock rewards.</p>' +
          '<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="' + pz.total + '" aria-valuenow="' + pz.found + '" aria-label="Symbols found"><span style="width:' + pct + '%"></span></div>' +
          '<p class="tiny">' + pz.found + ' of ' + pz.total + ' symbols found</p>' +
          '<div class="runes">' + (pz.open_cards || []).map(function (n) { return '<span class="rune' + (foundSet[n] ? " is-found" : "") + '">' + (foundSet[n] ? "✦ " : "") + esc(n) + '</span>'; }).join("") + '</div>' +
          '<form class="vform" novalidate data-k="sym"><div class="vfield"><label for="sym-card">Card number</label><input id="sym-card" inputmode="numeric" maxlength="3" placeholder="006"></div>' +
          '<div class="vfield"><label for="sym-ans">What did you find?</label><input id="sym-ans" autocomplete="off" spellcheck="false" maxlength="40"></div>' +
          '<button class="btn btn-ghost" type="submit">Check my answer</button><p class="vstatus" role="status" aria-live="polite"></p></form>'
                 : '<p>The first symbols open soon. Every vault door hides one. Keep your cards close, and your progress will show up here.</p>' +
          '<div class="progress" aria-hidden="true"><span style="width:0"></span></div><p class="tiny">0 symbols open yet</p>') +
      '</section>';
    $('[data-k="out"]', root).addEventListener("click", signOut);
    $('[data-k="edit"]', root).addEventListener("click", function () {
      var box = document.createElement("section"); box.className = "vpanel";
      root.insertBefore(box, root.children[1]);
      renderHandle(box, { onDone: function () { renderMyVaultAgain(); } });
      $("#h-in", box).focus();
    });
    renderClaimForm($("#mv-claim", root), "", { prefill: prefill, onClaimed: function () { renderMyVaultAgain(); } });
    var sf = $('form[data-k="sym"]', root);
    if (sf) sf.addEventListener("submit", function (e) {
      e.preventDefault();
      var st = $(".vstatus", sf), btn = $("button", sf);
      var n = normNo($("#sym-card", sf).value), a = $("#sym-ans", sf).value.trim();
      if (!n || !a) { setStatus(st, "Enter a card number and your answer.", "is-error"); return; }
      busy(btn, true, "Checking…");
      rpc("submit_symbol", { card_no: n, answer: a }).then(function (r) {
        busy(btn, false);
        if (!r || !r.ok) { setStatus(st, (r && r.message) || "Try again.", "is-error"); return; }
        if (r.correct) { setStatus(st, "Unlocked! " + r.found + " of " + r.total + " found.", "is-ok"); setTimeout(renderMyVaultAgain, 900); }
        else setStatus(st, "Not quite. Look closer at the door.", "is-error");
      }).catch(function () { busy(btn, false); setStatus(st, "That didn't go through. Try again.", "is-error"); });
    });
  }
  function renderMyVaultAgain() {
    var root = $("#myvault");
    rpc("my_vault").then(function (v) { paintVault(root, v, ""); });
  }

  // ---------- boot ----------
  renderNav();
  renderFooter();
  var cardParam = new URLSearchParams(location.search).get("card");
  if (PAGE === "home") {
    var no = normNo(cardParam);
    if (cardParam !== null && no) { document.body.classList.add("is-card"); var nv = $(".vnav"); if (nv) nv.classList.remove("is-overlay"); renderCardPage(no); }
    renderGallery();
  }
  if (PAGE === "wall") renderWall();
  if (PAGE === "videos") renderVideos();
  if (PAGE === "vault") renderMyVault();
  initAuth();
  window.__vault = { state: state, rpc: rpc };
})();
