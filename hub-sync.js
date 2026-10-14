// hub-sync.js — shared real-time storage for hr-tasks.html and projects.html.
//
// Loaded after the Supabase JS CDN script and config.js. Exposes
// window.HubSync. If config.js is missing or the Supabase script failed to
// load, every method here becomes a harmless no-op and the calling page
// keeps working exactly as before, on localStorage alone — this file is
// additive, never a hard dependency.
//
// What this solves: hr-tasks.html and projects.html used to keep all their
// data in each person's own browser (localStorage), so "assign a task to a
// colleague" never actually let that colleague see it. This module syncs
// projects and tasks to a shared Supabase table (see
// supabase/hub-schema.sql) so assignment and project membership become
// real, server-enforced visibility — while each page's own rendering code
// stays untouched; only load()/save() change.
(function () {
  if (window.HubSync) return;

  var cfg = window.SUPABASE_CONFIG || {};
  var domain = window.PLEI_WORKSPACE_DOMAIN || "";
  var client = null;
  try {
    if (window.supabase && cfg.url && cfg.anonKey) {
      client = window.supabase.createClient(cfg.url, cfg.anonKey);
    }
  } catch (e) { console.warn("[hub-sync] init failed", e); client = null; }

  var session = null;
  var myProfile = null; // {id, email, name}
  var profilesByName = {};
  var profilesById = {};
  var authListeners = [];

  function lc(s) { return (s || "").toString().toLowerCase().trim(); }

  function notifyAuth() { authListeners.forEach(function (cb) { try { cb(session); } catch (e) {} }); }

  async function loadProfiles() {
    if (!client) return;
    var r = await client.from("profiles").select("*");
    if (r.error) { console.warn("[hub-sync] loadProfiles", r.error); return; }
    var byName = {}, byId = {};
    (r.data || []).forEach(function (p) { byName[lc(p.name)] = p; byId[p.id] = p; });
    profilesByName = byName; profilesById = byId;
  }

  async function afterSignIn() {
    var u = session.user;
    // The DB trigger that populates `profiles` from auth.users runs
    // asynchronously relative to this call returning, so poll briefly.
    for (var tries = 0; tries < 6; tries++) {
      var r = await client.from("profiles").select("*").eq("id", u.id);
      if (!r.error && r.data && r.data[0]) { myProfile = r.data[0]; break; }
      await new Promise(function (res) { setTimeout(res, 350); });
    }
    await loadProfiles();
    notifyAuth();
  }

  async function init() {
    if (!client) return { ok: false, reason: "no-config" };
    var got = await client.auth.getSession();
    session = got.data.session;
    if (session) await afterSignIn();
    client.auth.onAuthStateChange(function (_evt, sess) {
      var becameSignedIn = !session && sess;
      session = sess;
      if (becameSignedIn) afterSignIn(); else notifyAuth();
    });
    return { ok: true, signedIn: !!session };
  }

  function isInIframe() {
    try { return window.self !== window.top; } catch (e) { return true; }
  }

  async function signIn() {
    if (!client) return { ok: false, reason: "no-config" };
    if (isInIframe()) {
      // Google's sign-in screen generally refuses to render inside an
      // <iframe> (productivity.html embeds this page that way). Open the
      // real page in its own tab instead; once signed in there, the
      // session is picked up here too (same browser, same Supabase-origin
      // storage) the next time this iframe reloads.
      var url = window.location.href.replace(/([?&])embed=1(&|$)/, "$1").replace(/[?&]$/, "");
      window.open(url, "_blank");
      return { ok: true, openedNewTab: true };
    }
    var r = await client.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: window.location.origin + window.location.pathname + window.location.search,
        queryParams: domain ? { hd: domain } : {},
      },
    });
    if (r.error) return { ok: false, error: r.error };
    return { ok: true };
  }

  async function signOut() { if (client) await client.auth.signOut(); }

  function onAuthChange(cb) { authListeners.push(cb); }

  function resolveNameToId(name) { var p = profilesByName[lc(name)]; return p ? p.id : null; }
  function resolveIdToName(id) { var p = profilesById[id]; return p ? p.name : null; }
  function knownProfiles() { return Object.keys(profilesById).map(function (id) { return profilesById[id]; }); }

  // ---- generic debounced collection sync ---------------------------------
  // table: the Postgres table name ("hub_tasks" | "hub_projects")
  // toRow(obj): in-memory object -> row to upsert (must set id)
  // fromRow(row): row -> in-memory object shape the page expects
  // onRemote(payload): called on any realtime change from another tab/user
  function makeCollection(opts) {
    var table = opts.table;
    var toRow = opts.toRow;
    var fromRow = opts.fromRow;
    var onRemote = opts.onRemote || function () {};
    var lastPushed = {}; // id -> JSON string of the comparable fields last pushed/pulled
    var pending = {}; // id -> in-memory obj queued to push
    var pushTimer = null;
    var debounceMs = opts.debounceMs || 400;

    function comparable(row) {
      return JSON.stringify({ data: row.data, members: row.members, assignees: row.assignees, project_id: row.project_id, vis: row.vis, kind: row.kind });
    }

    async function pullAll() {
      if (!client) return null;
      var r = await client.from(table).select("*");
      if (r.error) { console.warn("[hub-sync] pull " + table, r.error); return null; }
      var rows = r.data || [];
      rows.forEach(function (row) { lastPushed[row.id] = comparable(row); });
      return rows.map(fromRow);
    }

    function queuePush(obj) {
      if (!client) return;
      pending[obj.id] = obj;
      if (pushTimer) clearTimeout(pushTimer);
      pushTimer = setTimeout(flush, debounceMs);
    }

    async function flush() {
      pushTimer = null;
      var ids = Object.keys(pending);
      if (!ids.length) return;
      var batch = ids.map(function (id) { return pending[id]; });
      pending = {};
      for (var i = 0; i < batch.length; i++) {
        var row = toRow(batch[i]);
        var cmp = comparable(row);
        if (lastPushed[row.id] === cmp) continue; // no real change, skip the round-trip
        var r = await client.from(table).upsert(row).select();
        if (r.error) { console.warn("[hub-sync] push " + table, row.id, r.error); continue; }
        lastPushed[row.id] = cmp;
      }
    }

    async function remove(id) {
      delete pending[id];
      delete lastPushed[id];
      if (!client) return;
      var r = await client.from(table).delete().eq("id", id);
      if (r.error) console.warn("[hub-sync] delete " + table, id, r.error);
    }

    function subscribe() {
      if (!client) return function () {};
      var channel = client
        .channel(table + "-changes-" + Math.random().toString(36).slice(2))
        .on("postgres_changes", { event: "*", schema: "public", table: table }, onRemote)
        .subscribe();
      return function () { client.removeChannel(channel); };
    }

    function invalidateAll() { lastPushed = {}; }

    return { pullAll: pullAll, queuePush: queuePush, flush: flush, remove: remove, subscribe: subscribe, invalidateAll: invalidateAll };
  }

  function subscribeProfiles(cb) {
    if (!client) return function () {};
    var channel = client
      .channel("profiles-changes-" + Math.random().toString(36).slice(2))
      .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, function (payload) {
        loadProfiles().then(function () { cb(payload); });
      })
      .subscribe();
    return function () { client.removeChannel(channel); };
  }

  window.HubSync = {
    enabled: !!client,
    init: init,
    signIn: signIn,
    signOut: signOut,
    onAuthChange: onAuthChange,
    isInIframe: isInIframe,
    getSession: function () { return session; },
    getMyProfile: function () { return myProfile; },
    reloadProfiles: loadProfiles,
    resolveNameToId: resolveNameToId,
    resolveIdToName: resolveIdToName,
    knownProfiles: knownProfiles,
    makeCollection: makeCollection,
    subscribeProfiles: subscribeProfiles,
  };
})();
