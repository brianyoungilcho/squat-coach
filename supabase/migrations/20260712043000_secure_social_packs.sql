create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regprocedure('public.pack_fetch(text,date)') is not null then
    execute 'revoke all on function public.pack_fetch(text, date) from public, anon, authenticated';
  end if;
  if to_regprocedure('public.pack_upsert(text,uuid,text,date,integer,integer)') is not null then
    execute 'revoke all on function public.pack_upsert(text, uuid, text, date, integer, integer) from public, anon, authenticated';
  end if;
end;
$$;
drop function if exists public.pack_fetch(text, date);
drop function if exists public.pack_upsert(text, uuid, text, date, integer, integer);
drop table if exists public.pack_days cascade;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.packs (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40 and name = btrim(name)),
  owner_id uuid not null references auth.users(id) on delete cascade,
  max_members smallint not null default 20 check (max_members between 2 and 50),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.pack_members (
  pack_id uuid not null references public.packs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null
    check (char_length(btrim(display_name)) between 1 and 40 and display_name = btrim(display_name)),
  role text not null default 'member' check (role in ('owner', 'member')),
  status text not null default 'active' check (status in ('active', 'left')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (pack_id, user_id),
  check ((status = 'active' and left_at is null) or (status = 'left' and left_at is not null))
);

create table public.workout_events (
  id bigint generated always as identity primary key,
  client_id uuid not null,
  pack_id uuid not null references public.packs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  occurred_at timestamptz not null,
  sets smallint not null check (sets between 1 and 50),
  reps smallint not null check (reps between 1 and 500),
  streak integer not null default 0 check (streak between 0 and 36500),
  created_at timestamptz not null default now(),
  unique (user_id, client_id),
  unique (pack_id, id)
);

create table public.reactions (
  id bigint generated always as identity primary key,
  pack_id uuid not null references public.packs(id) on delete cascade,
  event_id bigint not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('strong', 'fire', 'clap', 'cheer')),
  created_at timestamptz not null default now(),
  foreign key (pack_id, event_id)
    references public.workout_events(pack_id, id) on delete cascade,
  unique (event_id, user_id, kind)
);

alter publication supabase_realtime add table
  public.pack_members,
  public.workout_events,
  public.reactions;

create table private.pack_invites (
  id uuid primary key default extensions.gen_random_uuid(),
  pack_id uuid not null references public.packs(id) on delete cascade,
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null check (expires_at > created_at),
  revoked_at timestamptz,
  check (revoked_at is null or revoked_at >= created_at)
);

create unique index packs_one_owner_idx on public.packs (id, owner_id);
create index packs_owner_idx on public.packs (owner_id) where deleted_at is null;
create index packs_deleted_retention_idx on public.packs (deleted_at) where deleted_at is not null;
create index pack_members_user_active_idx on public.pack_members (user_id, pack_id)
  where status = 'active';
create index pack_members_pack_active_idx on public.pack_members (pack_id, joined_at)
  where status = 'active';
create index workout_events_pack_activity_idx on public.workout_events (pack_id, occurred_at desc, id desc);
create index workout_events_user_activity_idx on public.workout_events (user_id, occurred_at desc);
create index workout_events_retention_idx on public.workout_events (created_at);
create index reactions_event_idx on public.reactions (event_id, created_at);
create index reactions_pack_event_idx on public.reactions (pack_id, event_id);
create index reactions_user_idx on public.reactions (user_id);
create index reactions_pack_activity_idx on public.reactions (pack_id, created_at desc);
create index pack_invites_pack_active_idx on private.pack_invites (pack_id, expires_at)
  where revoked_at is null;
create index pack_invites_expiry_idx on private.pack_invites (expires_at);
create index pack_invites_created_by_idx on private.pack_invites (created_by);

alter table public.packs enable row level security;
alter table public.pack_members enable row level security;
alter table public.workout_events enable row level security;
alter table public.reactions enable row level security;
alter table private.pack_invites enable row level security;

revoke all on public.packs, public.pack_members, public.workout_events, public.reactions
  from public, anon, authenticated;
revoke all on private.pack_invites from public, anon, authenticated;
grant select, update, delete on public.packs to authenticated;
grant select, insert, delete on public.pack_members to authenticated;
grant update (display_name) on public.pack_members to authenticated;
grant select, insert on public.workout_events to authenticated;
grant select, insert, delete on public.reactions to authenticated;
grant usage, select on all sequences in schema public to authenticated;

create or replace function private.is_active_pack_member(p_pack_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.pack_members as member
    join public.packs as pack on pack.id = member.pack_id
    where member.pack_id = p_pack_id
      and member.user_id = p_user_id
      and member.status = 'active'
      and pack.deleted_at is null
  );
$$;

create or replace function private.is_pack_owner(p_pack_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.packs as pack
    where pack.id = p_pack_id
      and pack.owner_id = p_user_id
      and pack.deleted_at is null
  );
$$;

revoke all on function private.is_active_pack_member(uuid, uuid) from public;
revoke all on function private.is_pack_owner(uuid, uuid) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_active_pack_member(uuid, uuid) to authenticated;
grant execute on function private.is_pack_owner(uuid, uuid) to authenticated;

create policy packs_read_members
on public.packs for select to authenticated
using (private.is_active_pack_member(id, (select auth.uid())));

create policy packs_update_owner
on public.packs for update to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

create policy packs_delete_owner
on public.packs for delete to authenticated
using (owner_id = (select auth.uid()));

create policy pack_members_read_pack
on public.pack_members for select to authenticated
using (private.is_active_pack_member(pack_id, (select auth.uid())));

create policy pack_members_insert_owner
on public.pack_members for insert to authenticated
with check (
  private.is_pack_owner(pack_id, (select auth.uid()))
  and user_id <> (select auth.uid())
  and role = 'member'
);

create policy pack_members_update_member_or_owner
on public.pack_members for update to authenticated
using (
  user_id = (select auth.uid())
  or private.is_pack_owner(pack_id, (select auth.uid()))
)
with check (
  (user_id = (select auth.uid()) and role = 'member')
  or (
    private.is_pack_owner(pack_id, (select auth.uid()))
    and (
      (user_id = (select auth.uid()) and role = 'owner')
      or (user_id <> (select auth.uid()) and role = 'member')
    )
  )
);

create policy pack_members_delete_member_or_owner
on public.pack_members for delete to authenticated
using (
  (user_id = (select auth.uid()) and role = 'member')
  or private.is_pack_owner(pack_id, (select auth.uid()))
);

create policy workout_events_read_pack
on public.workout_events for select to authenticated
using (private.is_active_pack_member(pack_id, (select auth.uid())));

create policy workout_events_insert_self
on public.workout_events for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_active_pack_member(pack_id, (select auth.uid()))
);

create policy reactions_read_pack
on public.reactions for select to authenticated
using (private.is_active_pack_member(pack_id, (select auth.uid())));

create policy reactions_insert_self
on public.reactions for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_active_pack_member(pack_id, (select auth.uid()))
);

create policy reactions_delete_self
on public.reactions for delete to authenticated
using (user_id = (select auth.uid()));

create or replace function private.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function private.enforce_pack_member_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_limit integer;
  active_count integer;
begin
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then
    return new;
  end if;

  perform 1 from public.packs where id = new.pack_id for update;
  select max_members into member_limit from public.packs where id = new.pack_id and deleted_at is null;
  if member_limit is null then
    raise exception 'Pack does not exist';
  end if;

  select count(*) into active_count
  from public.pack_members
  where pack_id = new.pack_id and status = 'active';

  if active_count >= member_limit then
    raise exception 'Pack is full';
  end if;
  return new;
end;
$$;

create or replace function private.protect_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_owner uuid;
begin
  if tg_op = 'UPDATE' and (
    new.user_id <> old.user_id or new.pack_id <> old.pack_id
  ) then
    raise exception 'Membership identity cannot be changed';
  end if;
  select owner_id into current_owner from public.packs where id = old.pack_id;
  if current_owner is null then
    return coalesce(new, old);
  end if;
  if old.user_id = current_owner and (
    tg_op = 'DELETE'
    or new.user_id <> old.user_id
    or new.pack_id <> old.pack_id
    or new.role <> 'owner'
    or new.status <> 'active'
  ) then
    raise exception 'The owner membership cannot be changed';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function private.set_updated_at() from public;
revoke all on function private.enforce_pack_member_limit() from public;
revoke all on function private.protect_owner_membership() from public;

create trigger packs_set_updated_at
before update on public.packs
for each row execute function private.set_updated_at();

create trigger pack_members_set_updated_at
before update on public.pack_members
for each row execute function private.set_updated_at();

create trigger pack_members_limit
before insert or update of status on public.pack_members
for each row execute function private.enforce_pack_member_limit();

create trigger pack_members_protect_owner
before update or delete on public.pack_members
for each row execute function private.protect_owner_membership();

create or replace function private.create_pack(
  p_actor uuid,
  p_name text,
  p_display_name text,
  p_max_members smallint,
  p_token_hash bytea,
  p_expires_at timestamptz
)
returns table (pack_id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_pack_id uuid := extensions.gen_random_uuid();
begin
  if p_actor is null then raise exception 'Authentication required'; end if;
  insert into public.packs (id, name, owner_id, max_members)
  values (new_pack_id, p_name, p_actor, p_max_members);
  insert into public.pack_members (pack_id, user_id, display_name, role)
  values (new_pack_id, p_actor, p_display_name, 'owner');
  insert into private.pack_invites (pack_id, token_hash, created_by, expires_at)
  values (new_pack_id, p_token_hash, p_actor, p_expires_at);
  return query select new_pack_id, p_expires_at;
end;
$$;

create or replace function private.join_pack(
  p_actor uuid,
  p_display_name text,
  p_token_hash bytea
)
returns table (pack_id uuid, pack_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  invite_pack_id uuid;
  invite_pack_name text;
begin
  if p_actor is null then raise exception 'Authentication required'; end if;
  select invite.pack_id, pack.name
    into invite_pack_id, invite_pack_name
  from private.pack_invites as invite
  join public.packs as pack on pack.id = invite.pack_id
  where invite.token_hash = p_token_hash
    and invite.revoked_at is null
    and invite.expires_at > now()
    and pack.deleted_at is null
  for update of invite;
  if invite_pack_id is null then raise exception 'Invite is invalid or expired'; end if;

  insert into public.pack_members (pack_id, user_id, display_name)
  values (invite_pack_id, p_actor, p_display_name)
  on conflict on constraint pack_members_pkey do update
    set display_name = excluded.display_name,
        status = 'active',
        left_at = null,
        joined_at = now();
  return query select invite_pack_id, invite_pack_name;
end;
$$;

create or replace function private.rotate_invite(
  p_actor uuid,
  p_pack_id uuid,
  p_token_hash bytea,
  p_expires_at timestamptz
)
returns table (invite_id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_invite_id uuid := extensions.gen_random_uuid();
begin
  if not private.is_pack_owner(p_pack_id, p_actor) then raise exception 'Owner access required'; end if;
  update private.pack_invites set revoked_at = now()
  where pack_id = p_pack_id and revoked_at is null;
  insert into private.pack_invites (id, pack_id, token_hash, created_by, expires_at)
  values (new_invite_id, p_pack_id, p_token_hash, p_actor, p_expires_at);
  return query select new_invite_id, p_expires_at;
end;
$$;

create or replace function private.leave_pack(p_actor uuid, p_pack_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_pack_owner(p_pack_id, p_actor) then
    raise exception 'Owners must delete the pack';
  end if;
  update public.pack_members
  set status = 'left', left_at = now()
  where pack_id = p_pack_id and user_id = p_actor and status = 'active';
  if not found then raise exception 'Active membership not found'; end if;
end;
$$;

create or replace function private.delete_pack(p_actor uuid, p_pack_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.packs
  where id = p_pack_id and owner_id = p_actor;
  if not found then raise exception 'Owner access required'; end if;
end;
$$;

revoke all on function private.create_pack(uuid, text, text, smallint, bytea, timestamptz) from public;
revoke all on function private.join_pack(uuid, text, bytea) from public;
revoke all on function private.rotate_invite(uuid, uuid, bytea, timestamptz) from public;
revoke all on function private.leave_pack(uuid, uuid) from public;
revoke all on function private.delete_pack(uuid, uuid) from public;
grant usage on schema private to service_role;
grant execute on function private.create_pack(uuid, text, text, smallint, bytea, timestamptz) to service_role;
grant execute on function private.join_pack(uuid, text, bytea) to service_role;
grant execute on function private.rotate_invite(uuid, uuid, bytea, timestamptz) to service_role;
grant execute on function private.leave_pack(uuid, uuid) to service_role;
grant execute on function private.delete_pack(uuid, uuid) to service_role;

create or replace function public.internal_create_pack(
  p_actor uuid, p_name text, p_display_name text, p_max_members smallint,
  p_token_hash bytea, p_expires_at timestamptz
)
returns table (pack_id uuid, expires_at timestamptz)
language sql security invoker set search_path = ''
as $$ select * from private.create_pack(p_actor, p_name, p_display_name, p_max_members, p_token_hash, p_expires_at) $$;

create or replace function public.internal_join_pack(p_actor uuid, p_display_name text, p_token_hash bytea)
returns table (pack_id uuid, pack_name text)
language sql security invoker set search_path = ''
as $$ select * from private.join_pack(p_actor, p_display_name, p_token_hash) $$;

create or replace function public.internal_rotate_invite(
  p_actor uuid, p_pack_id uuid, p_token_hash bytea, p_expires_at timestamptz
)
returns table (invite_id uuid, expires_at timestamptz)
language sql security invoker set search_path = ''
as $$ select * from private.rotate_invite(p_actor, p_pack_id, p_token_hash, p_expires_at) $$;

create or replace function public.internal_leave_pack(p_actor uuid, p_pack_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select private.leave_pack(p_actor, p_pack_id) $$;

create or replace function public.internal_delete_pack(p_actor uuid, p_pack_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select private.delete_pack(p_actor, p_pack_id) $$;

revoke all on function public.internal_create_pack(uuid, text, text, smallint, bytea, timestamptz) from public, anon, authenticated;
revoke all on function public.internal_join_pack(uuid, text, bytea) from public, anon, authenticated;
revoke all on function public.internal_rotate_invite(uuid, uuid, bytea, timestamptz) from public, anon, authenticated;
revoke all on function public.internal_leave_pack(uuid, uuid) from public, anon, authenticated;
revoke all on function public.internal_delete_pack(uuid, uuid) from public, anon, authenticated;
grant execute on function public.internal_create_pack(uuid, text, text, smallint, bytea, timestamptz) to service_role;
grant execute on function public.internal_join_pack(uuid, text, bytea) to service_role;
grant execute on function public.internal_rotate_invite(uuid, uuid, bytea, timestamptz) to service_role;
grant execute on function public.internal_leave_pack(uuid, uuid) to service_role;
grant execute on function public.internal_delete_pack(uuid, uuid) to service_role;
