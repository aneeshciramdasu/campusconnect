-- FINAL REVIEW MIGRATION - DO NOT EXECUTE YET
-- Apply only after the critical blockers below are resolved manually.

begin;

-- Abort if required tables or UUID-compatible columns are not as expected.
do $$
begin
  if to_regclass('public.users') is null
    or to_regclass('public.events') is null
    or to_regclass('public.registrations') is null
  then
    raise exception 'Required public tables are missing.';
  end if;

  if not exists (
    select 1
    from pg_attribute a
    where a.attrelid = 'public.users'::regclass
      and a.attname = 'id'
      and a.atttypid = 'uuid'::regtype
      and not a.attisdropped
  )
  or not exists (select 1 from pg_attribute a
                 where a.attrelid='public.events'::regclass
                   and a.attname='id' and a.atttypid='uuid'::regtype and not a.attisdropped)
  or not exists (select 1 from pg_attribute a
                 where a.attrelid='public.events'::regclass
                   and a.attname='organizer_id' and a.atttypid='uuid'::regtype and not a.attisdropped)
  or not exists (select 1 from pg_attribute a
                 where a.attrelid='public.registrations'::regclass
                   and a.attname='user_id' and a.atttypid='uuid'::regtype and not a.attisdropped)
  or not exists (select 1 from pg_attribute a
                 where a.attrelid='public.registrations'::regclass
                   and a.attname='event_id' and a.atttypid='uuid'::regtype and not a.attisdropped)
  then
    raise exception 'Required identity/event columns must use UUID.';
  end if;

  if not exists (
    select 1
    from pg_attribute a
    where a.attrelid = 'public.events'::regclass
      and a.attname = 'capacity'
      and not a.attisdropped
  )
  or not exists (
    select 1
    from pg_attribute a
    where a.attrelid = 'public.events'::regclass
      and a.attname = 'status'
      and not a.attisdropped
  )
  then
    raise exception 'public.events must contain capacity and status.';
  end if;
end;
$$;

-- Preserve data and abort on existing integrity conflicts.
do $$
begin
  if exists (
    select 1
    from public.registrations
    group by user_id, event_id
    having count(*) > 1
  ) then
    raise exception 'Duplicate registrations exist.';
  end if;

  if exists (
    select 1
    from public.registrations r
    left join public.users u on u.id = r.user_id
    where u.id is null
  ) then
    raise exception 'Registrations reference missing public users.';
  end if;

  if exists (
    select 1
    from public.registrations r
    left join public.events e on e.id = r.event_id
    where e.id is null
  ) then
    raise exception 'Registrations reference missing events.';
  end if;

  if exists (
    select 1
    from public.events e
    left join public.users u on u.id = e.organizer_id
    where u.id is null
  ) then
    raise exception 'Events reference missing organizers.';
  end if;

  if exists (
    select 1
    from public.events e
    left join public.registrations r on r.event_id = e.id
    group by e.id, e.capacity
    having count(r.id) > e.capacity
  ) then
    raise exception 'One or more events are over capacity.';
  end if;
end;
$$;

-- Explicit identity mapping: no values are inferred or inserted.
create table if not exists public.auth_user_mappings (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  legacy_user_id uuid not null,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'auth_user_mappings_legacy_user_id_fkey'
      and conrelid = 'public.auth_user_mappings'::regclass
  ) then
    alter table public.auth_user_mappings
      add constraint auth_user_mappings_legacy_user_id_fkey
      foreign key (legacy_user_id) references public.users(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'auth_user_mappings_legacy_user_id_key'
      and conrelid = 'public.auth_user_mappings'::regclass
  ) then
    alter table public.auth_user_mappings
      add constraint auth_user_mappings_legacy_user_id_key
      unique (legacy_user_id);
  end if;

  -- Legacy public users remain untouched. They may stay unmapped.
  -- Only manually confirmed mappings are used for registration/ownership.
  if exists (
    select 1
    from public.auth_user_mappings m
    left join auth.users au on au.id = m.auth_user_id
    left join public.users u on u.id = m.legacy_user_id
    where au.id is null or u.id is null
  ) then
    raise exception 'Auth user mappings contain missing Auth or public users.';
  end if;
end;
$$;

-- Exact-ID profile creation for new Auth users. Existing profiles are never overwritten.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id, email, role)
  values (new.id, new.email, 'student')
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public;
revoke all on function public.handle_new_auth_user() from anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update of email on auth.users
for each row
execute function public.handle_new_auth_user();

-- Backfill only exact Auth IDs that have no public profile.
insert into public.users (id, email, role)
select au.id, au.email, 'student'
from auth.users au
where not exists (
  select 1
  from public.users u
  where u.id = au.id
)
on conflict (id) do nothing;

-- Foreign keys and duplicate protection.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'registrations_user_id_fkey'
      and conrelid = 'public.registrations'::regclass
  ) then
    alter table public.registrations
      add constraint registrations_user_id_fkey
      foreign key (user_id) references public.users(id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'registrations_event_id_fkey'
      and conrelid = 'public.registrations'::regclass
  ) then
    alter table public.registrations
      add constraint registrations_event_id_fkey
      foreign key (event_id) references public.events(id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'events_organizer_id_fkey'
      and conrelid = 'public.events'::regclass
  ) then
    alter table public.events
      add constraint events_organizer_id_fkey
      foreign key (organizer_id) references public.users(id)
      on delete restrict;
  end if;
end;
$$;

create unique index if not exists registrations_user_event_unique
  on public.registrations (user_id, event_id);

-- Atomic registration. Uses auth.uid() and the explicitly reviewed mapping table.
create or replace function public.register_for_event(p_event_id uuid)
returns public.registrations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_user_id uuid;
  v_event public.events%rowtype;
  v_registration public.registrations%rowtype;
begin
  if v_auth_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select m.legacy_user_id
  into v_user_id
  from public.auth_user_mappings m
  where m.auth_user_id = v_auth_user_id;

  if v_user_id is null then
    v_user_id := v_auth_user_id;
  end if;

  if not exists (
    select 1 from public.users u where u.id = v_user_id
  ) then
    raise exception 'Student profile not found' using errcode = '42501';
  end if;

  select *
  into v_event
  from public.events
  where id = p_event_id
  for update;

  if v_event.id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if v_event.status is distinct from 'open' then
    raise exception 'Event is closed' using errcode = '22023';
  end if;

  if (
    select count(*)
    from public.registrations r
    where r.event_id = p_event_id
  ) >= v_event.capacity then
    raise exception 'Event full' using errcode = 'P0001';
  end if;

  insert into public.registrations (user_id, event_id)
  values (v_user_id, p_event_id)
  on conflict (user_id, event_id) do nothing
  returning * into v_registration;

  if v_registration.id is null then
    raise exception 'Duplicate registration' using errcode = '23505';
  end if;

  return v_registration;
end;
$$;

revoke all on function public.register_for_event(uuid) from public;
revoke all on function public.register_for_event(uuid) from anon;
grant execute on function public.register_for_event(uuid) to authenticated;

-- RLS.
alter table public.users enable row level security;
alter table public.events enable row level security;
alter table public.registrations enable row level security;
alter table public.auth_user_mappings enable row level security;

drop policy if exists users_select_own on public.users;
create policy users_select_own
on public.users for select to authenticated
using (
  id = auth.uid()
  or exists (
    select 1 from public.auth_user_mappings m
    where m.auth_user_id = auth.uid()
      and m.legacy_user_id = users.id
  )
);

drop policy if exists events_select_public on public.events;
create policy events_select_public
on public.events for select to anon, authenticated
using (true);

drop policy if exists registrations_select_own on public.registrations;
create policy registrations_select_own
on public.registrations for select to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.auth_user_mappings m
    where m.auth_user_id = auth.uid()
      and m.legacy_user_id = registrations.user_id
  )
  or exists (
    select 1 from public.events e
    where e.id = registrations.event_id
      and (
        e.organizer_id = auth.uid()
        or exists (
          select 1 from public.auth_user_mappings m
          where m.auth_user_id = auth.uid()
            and m.legacy_user_id = e.organizer_id
        )
      )
  )
);

drop policy if exists mappings_select_own on public.auth_user_mappings;
create policy mappings_select_own
on public.auth_user_mappings for select to authenticated
using (auth_user_id = auth.uid());

-- Direct profile updates, registration inserts, registration deletes, and role updates are denied.
-- Registration is possible only through the granted register_for_event function.

commit;

-- Minimal post-migration smoke test (read-only):
-- select relrowsecurity, relforcerowsecurity
-- from pg_class
-- where oid in (
--   'public.users'::regclass,
--   'public.events'::regclass,
--   'public.registrations'::regclass,
--   'public.auth_user_mappings'::regclass
-- );
--
-- select tablename, policyname, cmd, roles
-- from pg_policies
-- where schemaname='public'
--   and tablename in ('users','events','registrations','auth_user_mappings');
--
-- select has_function_privilege('authenticated',
--   'public.register_for_event(uuid)', 'EXECUTE') as authenticated_can_register,
--   has_function_privilege('anon',
--   'public.register_for_event(uuid)', 'EXECUTE') as anon_can_register;
