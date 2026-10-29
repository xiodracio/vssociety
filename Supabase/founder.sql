-- =====================================================================
-- VARONIS portal  ·  set the Founder login
-- Run AFTER schema.sql, in the Supabase SQL Editor. Edit the two values below first.
-- Run it again any time to change the Founder username or password.
--
-- Do NOT commit this file to GitHub with your real password in it. Edit it in the
-- SQL Editor only, or keep this repo copy with the placeholders untouched.
-- =====================================================================
do $$
declare
  v_user text := 'CHANGE_ME_USERNAME';
  v_pass text := 'CHANGE_ME_PASSWORD';
begin
  if v_user like 'CHANGE_ME%' or v_pass like 'CHANGE_ME%' then
    raise exception 'Edit v_user and v_pass first, then run again.';
  end if;
  if length(v_pass) < 10 then
    raise exception 'Use at least 10 characters for the Founder password.';
  end if;
  insert into public.founder (id, username, pass_hash)
    values (1, v_user, extensions.crypt(v_pass, extensions.gen_salt('bf', 10)))
  on conflict (id) do update set username = excluded.username, pass_hash = excluded.pass_hash;
  delete from public.sessions where role = 'admin';          -- sign out any old Founder session
end $$;
