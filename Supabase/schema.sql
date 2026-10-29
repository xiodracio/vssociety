-- =====================================================================
-- VARONIS portal  ·  Supabase schema
-- Run this whole file once in:  Supabase dashboard → SQL Editor → New query → Run
-- Safe to re-run later (it only creates what is missing / replaces functions).
--
-- How it is locked down:
--   * Every table has Row Level Security ON and NO policies, so the public
--     "anon" key in the website cannot read or write them directly.
--   * The site talks to the database only through the vr_* functions below.
--     Each one checks a session token (issued at login) before doing anything.
--   * The only things the public key can read are `feed` (the Global Archive:
--     masked member codes only) and `pings` (a counter used to refresh screens).
--     That is what makes the archive update live for everyone.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------------------------------------------------

create table if not exists public.members (
  id          uuid primary key default gen_random_uuid(),
  name        text        not null,
  username    text        not null,
  pass_hash   text        not null,                       -- bcrypt, used to sign in
  k           text        not null check (k in ('VR','FM','CK','CR','WD','CL')),
  code        text        not null unique,
  pts         integer     not null default 0 check (pts >= 0),
  is_mod      boolean     not null default false,
  created_at  timestamptz not null default now()
);
create unique index if not exists members_username_ci on public.members (lower(username));

-- Readable copy of each password so the Founder / moderators can look it up in
-- the console (this is the "Show" button). Only vr_list() can read it, and
-- moderators never get another moderator's. To stop keeping readable passwords:
--   drop table public.member_secrets;   (the console then shows "Not recorded")
create table if not exists public.member_secrets (
  member_id uuid primary key references public.members(id) on delete cascade,
  pw        text not null
);

create table if not exists public.used_codes (            -- codes are never reused,
  code text primary key                                    -- even after a member is removed
);

create table if not exists public.points_log (
  id        bigserial primary key,
  member_id uuid not null references public.members(id) on delete cascade,
  d         integer not null,
  note      text,
  logged_at timestamptz not null default now()
);
create index if not exists points_log_member on public.points_log (member_id, id desc);

create table if not exists public.founder (
  id        integer primary key default 1 check (id = 1),
  username  text not null,
  pass_hash text not null
);

create table if not exists public.sessions (
  token_hash text primary key,                             -- sha256 of the token the browser holds
  role       text not null check (role in ('admin','member')),
  member_id  uuid references public.members(id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists sessions_member on public.sessions (member_id);

create table if not exists public.login_attempts (
  key          text primary key,
  n            integer not null default 0,
  locked_until timestamptz,
  updated_at   timestamptz not null default now()
);

create table if not exists public.feed (                   -- the Global Archive
  id        bigserial primary key,
  bot       boolean not null default true,
  code      text    not null,                              -- already masked, e.g. FM26***
  k         text    not null,
  x         text    not null,
  posted_at timestamptz not null default now()
);

create table if not exists public.pings (                  -- "something changed" counter
  id integer primary key default 1 check (id = 1),
  n  bigint  not null default 0
);
insert into public.pings (id, n) values (1, 0) on conflict (id) do nothing;

-- ---------- lock the tables ------------------------------------------

alter table public.members        enable row level security;
alter table public.member_secrets enable row level security;
alter table public.used_codes     enable row level security;
alter table public.points_log     enable row level security;
alter table public.founder        enable row level security;
alter table public.sessions       enable row level security;
alter table public.login_attempts enable row level security;
alter table public.feed           enable row level security;
alter table public.pings          enable row level security;

revoke all on public.members, public.member_secrets, public.used_codes, public.points_log,
              public.founder, public.sessions, public.login_attempts, public.feed, public.pings
  from anon, authenticated;
grant select on public.feed, public.pings to anon, authenticated;

drop policy if exists "archive is public read" on public.feed;
create policy "archive is public read" on public.feed  for select to anon, authenticated using (true);
drop policy if exists "pings are public read"  on public.pings;
create policy "pings are public read"  on public.pings for select to anon, authenticated using (true);

-- ---------- realtime --------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'feed') then
    alter publication supabase_realtime add table public.feed;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pings') then
    alter publication supabase_realtime add table public.pings;
  end if;
end $$;

-- ---------- internal helpers (not callable from the website) ---------

create or replace function public._vr_bump() returns void
language sql security definer set search_path = public, extensions as
$$ update public.pings set n = n + 1 where id = 1 $$;

create or replace function public._vr_session(p_token text) returns public.sessions
language plpgsql security definer set search_path = public, extensions as $$
declare v_s public.sessions;
begin
  if p_token is null or length(p_token) < 20 then raise exception 'SESSION' using errcode = '28000'; end if;
  select * into v_s from public.sessions
   where token_hash = encode(digest(p_token, 'sha256'), 'hex') and expires_at > now();
  if not found then raise exception 'SESSION' using errcode = '28000'; end if;
  return v_s;
end $$;

-- returns 'founder' or 'mod'; anyone else is refused
create or replace function public._vr_staff(p_token text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_s public.sessions;
begin
  v_s := public._vr_session(p_token);
  if v_s.role = 'admin' then return 'founder'; end if;
  if exists (select 1 from public.members where id = v_s.member_id and is_mod) then return 'mod'; end if;
  raise exception 'Not allowed.';
end $$;

create or replace function public._vr_founder(p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_s public.sessions;
begin
  v_s := public._vr_session(p_token);
  if v_s.role <> 'admin' then raise exception 'Not allowed.'; end if;
end $$;

-- random atmospheric entry for the Archive
create or replace function public._vr_gen_post() returns table (code text, k text, x text)
language plpgsql volatile as $$
declare
  ks text[] := array['VR','FM','CK','CR','WD','CL'];
  ns text[] := array['Initiate','Founding Member','Circle Keeper','Curator','Warden','Council'];
  pv int[]  := array[100,250,500,1000];
  i  int    := floor(random() * 6)::int;
  n  int    := pv[1 + floor(random() * 4)::int];
  xs text[];
begin
  xs := array['cleared the Midnight Protocol','decoded the third cipher','was granted access to the Archive',
              'earned the Ember Seal','vouched a new initiate into the circle','reached ' || n || ' points',
              'was summoned to Level 2','recovered a sealed document','completed the Silent Oath'];
  if i < 5 then
    xs := xs || array['just got promoted to ' || ns[i + 2], 'just got promoted to ' || ns[i + 2]];
  end if;
  code := ks[i + 1] || lpad(floor(random() * 100)::int::text, 2, '0') || '***';
  k    := ks[i + 1];
  x    := xs[1 + floor(random() * array_length(xs, 1))::int];
  return next;
end $$;

revoke execute on function public._vr_bump(), public._vr_session(text), public._vr_staff(text),
                           public._vr_founder(text), public._vr_gen_post()
  from public, anon, authenticated;

-- ---------- functions the website calls ------------------------------

-- Sign in. p_role = 'member' | 'founder'. Returns {ok, token, role, id} or {ok:false[, locked, wait]}.
-- After 5 wrong tries in a row the wait doubles each time (30s, 1m, 2m ... max 15m), enforced here.
create or replace function public.vr_login(p_role text, p_user text, p_pass text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_user text := lower(trim(coalesce(p_user, '')));
  v_key  text;
  v_a    public.login_attempts;
  v_ok   boolean := false;
  v_mid  uuid;
  v_tok  text;
  v_n    int;
  v_wait int;
begin
  if coalesce(p_role, '') not in ('member', 'founder') or v_user = '' or length(v_user) > 64
     or p_pass is null or p_pass = '' or length(p_pass) > 200 then
    return jsonb_build_object('ok', false);
  end if;
  v_key := p_role || ':' || v_user;

  select * into v_a from public.login_attempts where key = v_key;
  if found and v_a.locked_until is not null and v_a.locked_until > now() then
    return jsonb_build_object('ok', false, 'locked', true,
             'wait', ceil(extract(epoch from (v_a.locked_until - now())))::int);
  end if;

  if p_role = 'founder' then
    select true into v_ok from public.founder
     where lower(username) = v_user and pass_hash = crypt(p_pass, pass_hash);
  else
    select id, true into v_mid, v_ok from public.members
     where lower(username) = v_user and pass_hash = crypt(p_pass, pass_hash);
  end if;
  v_ok := coalesce(v_ok, false);

  if not v_ok then
    perform crypt(p_pass, gen_salt('bf', 10));     -- keeps timing similar for unknown usernames
    insert into public.login_attempts as la (key, n, updated_at) values (v_key, 1, now())
      on conflict (key) do update set n = la.n + 1, updated_at = now()
      returning la.n into v_n;
    if v_n >= 5 then
      v_wait := least(30 * power(2, v_n - 5), 900)::int;
      update public.login_attempts set locked_until = now() + make_interval(secs => v_wait) where key = v_key;
      return jsonb_build_object('ok', false, 'locked', true, 'wait', v_wait);
    end if;
    return jsonb_build_object('ok', false);
  end if;

  delete from public.login_attempts where key = v_key;
  delete from public.sessions where expires_at < now();
  delete from public.login_attempts where updated_at < now() - interval '1 day'
                                      and (locked_until is null or locked_until < now());
  v_tok := encode(gen_random_bytes(32), 'hex');
  insert into public.sessions (token_hash, role, member_id, expires_at)
    values (encode(digest(v_tok, 'sha256'), 'hex'),
            case when p_role = 'founder' then 'admin' else 'member' end,
            case when p_role = 'founder' then null else v_mid end,
            now() + interval '24 hours');
  return jsonb_build_object('ok', true, 'token', v_tok,
           'role', case when p_role = 'founder' then 'admin' else 'member' end, 'id', v_mid);
end $$;

-- Who am I? null when the token is missing, expired, or the member was removed.
create or replace function public.vr_me(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_s public.sessions; v_m public.members;
begin
  if p_token is null or length(p_token) < 20 then return null; end if;
  select * into v_s from public.sessions
   where token_hash = encode(digest(p_token, 'sha256'), 'hex') and expires_at > now();
  if not found then return null; end if;
  if v_s.role = 'admin' then return jsonb_build_object('role', 'admin'); end if;
  select * into v_m from public.members where id = v_s.member_id;
  if not found then return null; end if;
  return jsonb_build_object('role', 'member', 'm', jsonb_build_object(
    'id', v_m.id, 'name', v_m.name, 'user', v_m.username, 'k', v_m.k, 'code', v_m.code,
    'pts', v_m.pts, 'mod', v_m.is_mod,
    'log', coalesce((select jsonb_agg(jsonb_build_object('d', x.d, 'n', x.note,
                       't', (extract(epoch from x.logged_at) * 1000)::bigint) order by x.id asc)
                     from (select * from public.points_log where member_id = v_m.id order by id desc limit 3) x),
                    '[]'::jsonb)));
end $$;

create or replace function public.vr_logout(p_token text) returns void
language sql security definer set search_path = public, extensions as
$$ delete from public.sessions where token_hash = encode(digest(p_token, 'sha256'), 'hex') $$;

-- Founder or moderator: every member. Moderators never see another moderator's password.
create or replace function public.vr_list(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_role text;
begin
  v_role := public._vr_staff(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'name', m.name, 'user', m.username, 'k', m.k, 'code', m.code,
      'pw', case when v_role = 'founder' or not m.is_mod then s.pw else null end,
      'pts', m.pts, 'mod', m.is_mod,
      'at', (extract(epoch from m.created_at) * 1000)::bigint) order by m.created_at asc)
    from public.members m left join public.member_secrets s on s.member_id = m.id), '[]'::jsonb);
end $$;

create or replace function public.vr_create(p_token text, p_name text, p_user text, p_pass text, p_k text, p_custom text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text; v_name text := trim(coalesce(p_name, '')); v_user text := trim(coalesce(p_user, ''));
  v_code text; v_n int := 0; v_id uuid;
begin
  v_role := public._vr_staff(p_token);
  if v_name = '' or length(v_name) > 80 then raise exception 'Enter a member name.'; end if;
  if length(v_user) < 2 or length(v_user) > 40 then raise exception 'Username must be 2 to 40 characters.'; end if;
  if p_pass is null or length(p_pass) < 6 or length(p_pass) > 200 then raise exception 'Password must be at least 6 characters.'; end if;
  if p_k is null or p_k not in ('VR','FM','CK','CR','WD','CL') then raise exception 'Choose a status.'; end if;
  if exists (select 1 from public.members where lower(username) = lower(v_user))
     or exists (select 1 from public.founder where lower(username) = lower(v_user)) then
    raise exception 'That username is already taken.';
  end if;

  if coalesce(p_custom, '') <> '' then
    if p_custom !~ '^[0-9]{5}$' then raise exception 'Enter exactly 5 digits for the code.'; end if;
    v_code := p_k || p_custom;
    if exists (select 1 from public.used_codes where code = v_code) then raise exception 'That code is already taken.'; end if;
  else
    loop
      v_n := v_n + 1;
      if v_n > 2000 then raise exception 'No codes left for this status.'; end if;
      v_code := p_k || lpad((1 + floor(random() * 99999))::int::text, 5, '0');
      exit when not exists (select 1 from public.used_codes where code = v_code);
    end loop;
  end if;

  begin
    insert into public.used_codes (code) values (v_code);
    insert into public.members (name, username, pass_hash, k, code)
      values (v_name, v_user, crypt(p_pass, gen_salt('bf', 10)), p_k, v_code) returning id into v_id;
    insert into public.member_secrets (member_id, pw) values (v_id, p_pass);
  exception when unique_violation then
    raise exception 'That username or code was just taken. Try again.';
  end;

  perform public._vr_bump();
  return jsonb_build_object('id', v_id, 'name', v_name, 'user', v_user, 'k', p_k, 'code', v_code);
end $$;

-- Award or deduct points. Positive awards also post (masked) to the Global Archive.
create or replace function public.vr_award(p_token text, p_id uuid, p_d integer, p_note text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_role text; v_m public.members; v_pts int;
begin
  v_role := public._vr_staff(p_token);
  if p_d is null or p_d = 0 or abs(p_d) > 1000000 then raise exception 'Enter a points value.'; end if;
  select * into v_m from public.members where id = p_id for update;
  if not found then raise exception 'Member not found.'; end if;
  if v_role = 'mod' and v_m.is_mod then raise exception 'Not allowed.'; end if;

  update public.members set pts = greatest(0, pts + p_d) where id = p_id returning pts into v_pts;
  insert into public.points_log (member_id, d, note)
    values (p_id, p_d, left(coalesce(nullif(trim(p_note), ''), case when p_d > 0 then 'Awarded' else 'Deducted' end), 40));
  delete from public.points_log where member_id = p_id
    and id not in (select id from public.points_log where member_id = p_id order by id desc limit 20);
  if p_d > 0 then
    insert into public.feed (bot, code, k, x) values (true, left(v_m.code, 4) || '***', v_m.k, 'was awarded +' || p_d || ' points');
  end if;
  perform public._vr_bump();
  return jsonb_build_object('pts', v_pts);
end $$;

create or replace function public.vr_setpw(p_token text, p_id uuid, p_pass text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_role text; v_m public.members;
begin
  v_role := public._vr_staff(p_token);
  if p_pass is null or length(p_pass) < 6 or length(p_pass) > 200 then raise exception 'Minimum 6 characters.'; end if;
  select * into v_m from public.members where id = p_id;
  if not found then raise exception 'Member not found.'; end if;
  if v_role = 'mod' and v_m.is_mod then raise exception 'Not allowed.'; end if;
  update public.members set pass_hash = crypt(p_pass, gen_salt('bf', 10)) where id = p_id;
  insert into public.member_secrets (member_id, pw) values (p_id, p_pass)
    on conflict (member_id) do update set pw = excluded.pw;
  delete from public.sessions where member_id = p_id;      -- signs them out everywhere
  perform public._vr_bump();
end $$;

create or replace function public.vr_setmod(p_token text, p_id uuid, p_val boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._vr_founder(p_token);
  update public.members set is_mod = coalesce(p_val, false) where id = p_id;
  if not found then raise exception 'Member not found.'; end if;
  perform public._vr_bump();
end $$;

create or replace function public.vr_remove(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_role text; v_m public.members;
begin
  v_role := public._vr_staff(p_token);
  select * into v_m from public.members where id = p_id;
  if not found then return; end if;
  if v_role = 'mod' and v_m.is_mod then raise exception 'Not allowed.'; end if;
  delete from public.members where id = p_id;              -- cascades secrets, log, sessions; the code stays retired
  perform public._vr_bump();
end $$;

-- Keeps the Global Archive moving. Any signed-in member's page calls this every ~20s while the
-- Archive is open; the database decides whether a new entry is due, so everyone sees one shared stream.
create or replace function public.vr_feed_tick(p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_last timestamptz; v_cnt int; v_gap interval; v_n int; v_i int; v_g record; v_recent text[]; v_tries int;
begin
  perform public._vr_session(p_token);
  perform pg_advisory_xact_lock(884201);                    -- one writer at a time

  select max(posted_at), count(*) into v_last, v_cnt from public.feed;
  if v_cnt < 5 then                                         -- archive (nearly) empty: seed some history
    for v_i in 1..14 loop
      select * into v_g from public._vr_gen_post();
      insert into public.feed (bot, code, k, x, posted_at)
        values (true, v_g.code, v_g.k, v_g.x,
                now() - make_interval(mins => (14 - v_i) * 12) + make_interval(secs => floor(random() * 300)::int));
    end loop;
    perform public._vr_bump();
    return;
  end if;

  v_gap := now() - v_last;
  if v_gap < make_interval(secs => 20 + random() * 30) then return; end if;

  v_n := case when v_gap > interval '10 minutes' then least(3, ceil(extract(epoch from v_gap) / 600)::int) else 1 end;
  for v_i in 1..v_n loop
    select coalesce(array_agg(f.code), '{}') into v_recent
      from (select code from public.feed order by id desc limit 40) f;
    v_tries := 0;
    loop
      select * into v_g from public._vr_gen_post();
      v_tries := v_tries + 1;
      exit when not (v_g.code = any (v_recent)) or v_tries > 30;
    end loop;
    insert into public.feed (bot, code, k, x, posted_at)
      values (true, v_g.code, v_g.k, v_g.x,
              case when v_n = 1 then now() else v_last + v_gap * v_i / (v_n + 1) end);
  end loop;

  delete from public.feed where id <= coalesce((select id from public.feed order by id desc offset 150 limit 1), 0);
end $$;

-- let the website (public "anon" key) call these and nothing else
revoke execute on function
  public.vr_login(text, text, text), public.vr_me(text), public.vr_logout(text), public.vr_list(text),
  public.vr_create(text, text, text, text, text, text), public.vr_award(text, uuid, integer, text),
  public.vr_setpw(text, uuid, text), public.vr_setmod(text, uuid, boolean), public.vr_remove(text, uuid),
  public.vr_feed_tick(text)
  from public;
grant execute on function
  public.vr_login(text, text, text), public.vr_me(text), public.vr_logout(text), public.vr_list(text),
  public.vr_create(text, text, text, text, text, text), public.vr_award(text, uuid, integer, text),
  public.vr_setpw(text, uuid, text), public.vr_setmod(text, uuid, boolean), public.vr_remove(text, uuid),
  public.vr_feed_tick(text)
  to anon, authenticated;
