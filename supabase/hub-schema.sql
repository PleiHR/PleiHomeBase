-- Plei Home Base — Hub shared storage (Round 21)
--
-- Adds shared, real-time, membership-aware storage for the pages that live
-- INSIDE the existing Hub, at the existing hub.plei.com domain, in this same
-- PleiHomeBase repo — nothing moves to a separate app:
--   - hr-tasks.html  (Board + the "Projects" tab inside it)
--   - projects.html  ("Projects & Sprints")
-- Both currently keep everything in per-browser localStorage, which is why
-- "assign a task to a colleague" never actually let that colleague see it —
-- each person only ever saw their own browser's copy. This schema fixes
-- that at the database level.
--
-- This runs against the SAME Supabase project already used by
-- plei-candidate-pipeline (https://ewrdyxafmvrunuratymp.supabase.co) — no
-- new project, no new cost, and Google Workspace sign-in ("Continue with
-- Google", restricted to @plei.com) is already configured there. Run this
-- file once in that project's SQL Editor (Dashboard → SQL Editor → New
-- query → paste → Run). Safe to re-run: everything is IF NOT EXISTS /
-- CREATE OR REPLACE / DROP POLICY IF EXISTS.
--
-- Forms, Comments, and Custom Field *definitions* are intentionally NOT
-- covered here (v1 scope: Tasks + Projects first). Per-task comments,
-- checklist items and subtasks ARE covered for free — they already live
-- INSIDE each task's own JSON object in hr-tasks.html, and this schema
-- stores that whole object as one row, so they travel with it automatically.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- profiles — one row per person who has signed in at least once, kept in
-- sync with Supabase Auth automatically. This is what makes "assign to X"
-- a real, enforced grant: X must have signed in at least once (so their
-- profile row — and uuid — exists) before assigning them actually unlocks
-- their access. Until then they still show up by name in the picker (same
-- as today), it just won't be backed by a real grant yet.
-- ---------------------------------------------------------------------------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- Real, unbypassable domain check — same function name/body already used by
-- plei-candidate-pipeline's schema in this same project; CREATE OR REPLACE
-- keeps it identical rather than colliding.
create or replace function is_staff_domain()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() ->> 'email') ilike '%@plei.com', false);
$$;

-- keep updated_at columns current — same helper plei-candidate-pipeline's
-- schema already created in this project; CREATE OR REPLACE keeps it in sync
-- rather than colliding, and lets this file also run standalone on a fresh
-- project.
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Populate/refresh profiles from auth.users on every sign-in. security
-- definer so it can write regardless of the signed-in user's own RLS.
create or replace function sync_profile_from_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email,'@',1))
  )
  on conflict (id) do update set
    email = excluded.email,
    name = excluded.name;
  return new;
end;
$$;

drop trigger if exists on_auth_user_upsert_sync_profile on auth.users;
create trigger on_auth_user_upsert_sync_profile
after insert or update on auth.users
for each row execute function sync_profile_from_auth_user();

drop policy if exists profiles_staff_select on profiles;
create policy profiles_staff_select
on profiles for select
to authenticated
using (is_staff_domain());
-- No insert/update/delete policy for `authenticated` on purpose: only the
-- trigger above (security definer) ever writes this table.

-- ---------------------------------------------------------------------------
-- hub_projects — one row per project, from BOTH tools:
--   kind='tasks'   -> a project from hr-tasks.html's "Projects" tab
--   kind='sprints' -> a project from projects.html ("Projects & Sprints")
-- `data` is the ENTIRE project object exactly as that page already keeps it
-- in memory (name/desc/area/statuses for hr-tasks.html; name/sprints/items
-- for projects.html) — unchanged shape, so neither page's rendering code
-- needs a rewrite, only load()/save().
-- `members`: uuid[] of profiles.id allowed to see/edit this project (and,
-- for kind='tasks', its tasks in hub_tasks below). An EMPTY array (the
-- default) means "visible to the whole company", matching how every
-- existing project behaves today — so nothing already created becomes
-- invisible the day this ships.
-- ---------------------------------------------------------------------------
create table if not exists hub_projects (
  id text primary key,
  kind text not null check (kind in ('tasks','sprints')),
  data jsonb not null default '{}'::jsonb,
  members uuid[] not null default '{}',
  created_by uuid references profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index if not exists hub_projects_kind_idx on hub_projects(kind);
create index if not exists hub_projects_members_idx on hub_projects using gin(members);

alter table hub_projects enable row level security;

-- Once a project/task row is created, its creator never changes again —
-- even if a later upsert payload includes a different created_by (the sync
-- client always sends the CURRENT editor as created_by for simplicity; this
-- trigger is what keeps that from quietly reassigning authorship on every
-- edit by someone else).
create or replace function preserve_created_by()
returns trigger language plpgsql as $$
begin
  new.created_by = old.created_by;
  return new;
end;
$$;

drop trigger if exists hub_projects_set_updated_at on hub_projects;
create trigger hub_projects_set_updated_at
before update on hub_projects
for each row execute function set_updated_at();

drop trigger if exists hub_projects_preserve_created_by on hub_projects;
create trigger hub_projects_preserve_created_by
before update on hub_projects
for each row execute function preserve_created_by();

-- security definer: lets a membership check run even when the row being
-- checked wouldn't otherwise be selectable by the caller — avoids the
-- classic recursive-RLS trap.
create or replace function is_hub_project_visible(p_members uuid[])
returns boolean language sql stable security definer set search_path = public as $$
  select p_members = '{}'::uuid[] or auth.uid() = any(p_members);
$$;

grant execute on function is_hub_project_visible(uuid[]) to authenticated;

drop policy if exists hub_projects_select on hub_projects;
create policy hub_projects_select
on hub_projects for select
to authenticated
using (is_staff_domain() and is_hub_project_visible(members));

drop policy if exists hub_projects_insert on hub_projects;
create policy hub_projects_insert
on hub_projects for insert
to authenticated
with check (is_staff_domain() and created_by = auth.uid());

drop policy if exists hub_projects_update on hub_projects;
create policy hub_projects_update
on hub_projects for update
to authenticated
using (is_staff_domain() and is_hub_project_visible(members))
with check (is_staff_domain());

drop policy if exists hub_projects_delete on hub_projects;
create policy hub_projects_delete
on hub_projects for delete
to authenticated
using (is_staff_domain() and is_hub_project_visible(members));

-- ---------------------------------------------------------------------------
-- hub_tasks — one row per task from hr-tasks.html's Board + Projects tab
-- (projects.html's own "items" live nested inside hub_projects.data instead
-- — that page never had a separate tasks list). `data` is the whole task
-- object unchanged (title, due, priority, subtasks, notes/comments,
-- checklist, custom field values, files — whatever shape hr-tasks.html
-- already uses), so all of that keeps working with zero rendering changes.
--
-- Visibility rule for a task — visible to a signed-in @plei.com user if
-- ANY of:
--   1. they are one of its assignees (the literal ask: "si alguien agrega
--      una task y se lo asigna a alguien esa otra persona lo pueda ver")
--   2. they created it
--   3. its vis is "company" (the default) AND its project (if any) is
--      itself visible to them — so a company-visible task inside a
--      restricted project still doesn't leak to non-members, but a
--      company-visible task with no project is open to everyone, same as
--      today.
-- A task marked "team" or "private" (existing field, previously
-- decorative-only) is NOT shown company-wide anymore — only to its
-- assignees/creator — which is the first time that field actually means
-- something.
-- ---------------------------------------------------------------------------
create table if not exists hub_tasks (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  project_id text references hub_projects(id) on delete set null,
  vis text not null default 'company',
  assignees uuid[] not null default '{}',
  created_by uuid references profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index if not exists hub_tasks_project_idx on hub_tasks(project_id);
create index if not exists hub_tasks_assignees_idx on hub_tasks using gin(assignees);

alter table hub_tasks enable row level security;

drop trigger if exists hub_tasks_set_updated_at on hub_tasks;
create trigger hub_tasks_set_updated_at
before update on hub_tasks
for each row execute function set_updated_at();

drop trigger if exists hub_tasks_preserve_created_by on hub_tasks;
create trigger hub_tasks_preserve_created_by
before update on hub_tasks
for each row execute function preserve_created_by();

create or replace function is_hub_task_visible(p_assignees uuid[], p_created_by uuid, p_vis text, p_project_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select
    auth.uid() = any(p_assignees)
    or auth.uid() = p_created_by
    or (
      coalesce(p_vis, 'company') = 'company'
      and (
        p_project_id is null
        or exists (
          select 1 from hub_projects hp
          where hp.id = p_project_id and is_hub_project_visible(hp.members)
        )
      )
    );
$$;

grant execute on function is_hub_task_visible(uuid[], uuid, text, text) to authenticated;

drop policy if exists hub_tasks_select on hub_tasks;
create policy hub_tasks_select
on hub_tasks for select
to authenticated
using (is_staff_domain() and is_hub_task_visible(assignees, created_by, vis, project_id));

drop policy if exists hub_tasks_insert on hub_tasks;
create policy hub_tasks_insert
on hub_tasks for insert
to authenticated
with check (
  is_staff_domain() and created_by = auth.uid()
  and (
    project_id is null
    or exists (select 1 from hub_projects hp where hp.id = project_id and is_hub_project_visible(hp.members))
  )
);

drop policy if exists hub_tasks_update on hub_tasks;
create policy hub_tasks_update
on hub_tasks for update
to authenticated
using (is_staff_domain() and is_hub_task_visible(assignees, created_by, vis, project_id))
with check (
  is_staff_domain()
  and (
    project_id is null
    or exists (select 1 from hub_projects hp where hp.id = project_id and is_hub_project_visible(hp.members))
  )
);

drop policy if exists hub_tasks_delete on hub_tasks;
create policy hub_tasks_delete
on hub_tasks for delete
to authenticated
using (is_staff_domain() and is_hub_task_visible(assignees, created_by, vis, project_id));

-- ---------------------------------------------------------------------------
-- Realtime: so when someone adds a task and assigns it to a colleague, that
-- colleague's board updates live, without a refresh — same pattern already
-- used for the candidate pipeline.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table profiles;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table hub_projects;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table hub_tasks;
  exception when duplicate_object then null;
  end;
end $$;
