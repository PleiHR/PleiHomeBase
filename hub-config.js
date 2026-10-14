// Hub shared-storage config (Round 21) — used by hub-sync.js on hr-tasks.html
// and projects.html only. This is the SAME Supabase project already used by
// plei-candidate-pipeline (https://ewrdyxafmvrunuratymp.supabase.co) — Tasks
// and Projects just add their own new tables to it (see
// supabase/hub-schema.sql), so there's no new project to create, no new
// cost, and Google Workspace sign-in ("Continue with Google", restricted to
// @plei.com) is already configured and working there.
//
// hiring-pipeline.html is unrelated to this file and unaffected by it — it
// uses its own, separate Firebase-based admin gate and is not part of this
// round's scope.
window.SUPABASE_CONFIG = {
  url: "https://ewrdyxafmvrunuratymp.supabase.co",
  anonKey: "sb_publishable_zJ9lWeDOpern0QZsosCnng_3XG771TL",
};

// Google Workspace domain allowed to sign in. Client-side UI hint only —
// the real, unbypassable check is is_staff_domain() in
// supabase/hub-schema.sql.
window.PLEI_WORKSPACE_DOMAIN = "plei.com";
