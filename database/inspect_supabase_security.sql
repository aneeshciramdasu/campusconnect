-- Read-only Supabase SQL Editor inspection queries
-- Run manually. Do not execute migration or data-changing statements.

-- 1. Public table column types, defaults, and nullability
select
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name in ('users', 'events', 'registrations')
order by c.table_name, c.ordinal_position;

-- 2. Primary and unique constraints
select
  tc.table_name,
  tc.constraint_name,
  tc.constraint_type,
  tc.is_deferrable,
  tc.initially_deferred
from information_schema.table_constraints tc
where tc.table_schema = 'public'
  and tc.table_name in ('users', 'events', 'registrations')
  and tc.constraint_type in ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
order by tc.table_name, tc.constraint_type, tc.constraint_name;

-- 3. Foreign-key details
select
  tc.table_name,
  tc.constraint_name,
  kcu.column_name,
  ccu.table_name as referenced_table,
  ccu.column_name as referenced_column,
  rc.delete_rule,
  rc.update_rule
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on kcu.constraint_name = tc.constraint_name
 and kcu.constraint_schema = tc.constraint_schema
join information_schema.constraint_column_usage ccu
  on ccu.constraint_name = tc.constraint_name
 and ccu.constraint_schema = tc.constraint_schema
join information_schema.referential_constraints rc
  on rc.constraint_name = tc.constraint_name
 and rc.constraint_schema = tc.constraint_schema
where tc.table_schema = 'public'
  and tc.table_name in ('users', 'events', 'registrations')
  and tc.constraint_type = 'FOREIGN KEY'
order by tc.table_name, tc.constraint_name, kcu.ordinal_position;

-- 4. RLS enabled and forced
select
  n.nspname as table_schema,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('users', 'events', 'registrations')
order by c.relname;

-- 5. Existing RLS policies
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('users', 'events', 'registrations')
order by tablename, policyname;

-- 6. Triggers on public tables
select
  event_object_schema,
  event_object_table,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where event_object_schema in ('public', 'auth')
order by event_object_schema, event_object_table, trigger_name;

-- 7. Database functions related to authentication or registration
select
  n.nspname as function_schema,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer,
  p.proconfig as config_settings,
  pg_get_function_result(p.oid) as result_type
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'auth')
order by n.nspname, p.proname;

-- 8. Public user IDs that do not match auth user IDs
-- This assumes public.users.id is compatible with auth.users.id.
select count(*) as unmatched_public_user_ids
from public.users u
left join auth.users au on au.id::text = u.id::text
where au.id is null;

-- No personal values are selected.
select
  au.id is not null as matched_auth_id,
  count(*) as record_count
from public.users u
left join auth.users au on au.id::text = u.id::text
group by au.id is not null
order by matched_auth_id;

-- 9. Duplicate registrations, counts only
select
  user_id,
  event_id,
  count(*) as registration_count
from public.registrations
group by user_id, event_id
having count(*) > 1
order by registration_count desc;

-- 10. Registrations referring to missing users
select count(*) as registrations_with_missing_users
from public.registrations r
left join public.users u on u.id = r.user_id
where u.id is null;

-- 11. Registrations referring to missing events
select count(*) as registrations_with_missing_events
from public.registrations r
left join public.events e on e.id = r.event_id
where e.id is null;

-- 12. Events already at or over capacity
select
  e.id,
  e.capacity,
  count(r.id) as registration_count,
  count(r.id) - e.capacity as registrations_over_capacity
from public.events e
left join public.registrations r on r.event_id = e.id
group by e.id, e.capacity
having count(r.id) > e.capacity
order by registrations_over_capacity desc;

-- 13. Registration aggregate for all events
select
  e.id,
  e.capacity,
  e.status,
  count(r.id) as registration_count
from public.events e
left join public.registrations r on r.event_id = e.id
group by e.id, e.capacity, e.status
order by e.id;

-- 14. Confirmation that auth and public IDs are UUID-compatible
select
  pg_typeof(u.id) as public_user_id_type,
  pg_typeof(au.id) as auth_user_id_type
from public.users u
cross join (select id from auth.users limit 1) au
limit 1;
