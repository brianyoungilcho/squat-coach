\set ON_ERROR_STOP on
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(1);

do $$
declare
  owner_id constant uuid := '10000000-0000-4000-8000-000000000001';
  member_id constant uuid := '10000000-0000-4000-8000-000000000002';
  outsider_id constant uuid := '10000000-0000-4000-8000-000000000003';
  test_pack_id uuid;
  second_pack_id uuid;
  invite_hash bytea := extensions.digest('valid-invite', 'sha256');
  expired_hash bytea := extensions.digest('expired-invite', 'sha256');
  revoked_hash bytea := extensions.digest('revoked-invite', 'sha256');
  client_event_id uuid := '20000000-0000-4000-8000-000000000001';
  visible_count integer;
begin
  insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', owner_id, 'authenticated', 'authenticated',
      'pack-owner@example.invalid', now(), now()),
    ('00000000-0000-0000-0000-000000000000', member_id, 'authenticated', 'authenticated',
      'pack-member@example.invalid', now(), now()),
    ('00000000-0000-0000-0000-000000000000', outsider_id, 'authenticated', 'authenticated',
      'pack-outsider@example.invalid', now(), now());

  select created.pack_id into test_pack_id
  from private.create_pack(
    owner_id, 'Test Pack', 'Owner', 5::smallint, invite_hash, now() + interval '1 day'
  ) as created;
  perform private.join_pack(member_id, 'Member', invite_hash);

  insert into private.pack_invites (pack_id, token_hash, created_by, created_at, expires_at)
  values (
    test_pack_id, expired_hash, owner_id,
    now() - interval '1 day', now() - interval '1 second'
  );
  begin
    perform private.join_pack(outsider_id, 'Outsider', expired_hash);
    raise exception 'expired invite unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'expired invite unexpectedly succeeded' then raise; end if;
  end;

  insert into private.pack_invites (pack_id, token_hash, created_by, expires_at, revoked_at)
  values (test_pack_id, revoked_hash, owner_id, now() + interval '1 day', now());
  begin
    perform private.join_pack(outsider_id, 'Outsider', revoked_hash);
    raise exception 'revoked invite unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'revoked invite unexpectedly succeeded' then raise; end if;
  end;

  select created.pack_id into second_pack_id
  from private.create_pack(
    owner_id, 'Delete Test', 'Owner', 5::smallint,
    extensions.digest('delete-test', 'sha256'), now() + interval '1 day'
  ) as created;

  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  set local role authenticated;
  select count(*) into visible_count from public.packs where id = test_pack_id;
  if visible_count <> 0 then raise exception 'nonmember could read pack'; end if;
  reset role;

  perform set_config('request.jwt.claim.sub', member_id::text, true);
  set local role authenticated;
  begin
    update public.pack_members
    set pack_id = second_pack_id
    where pack_id = test_pack_id and user_id = member_id;
    raise exception 'member moved membership without an invite';
  exception when others then
    if sqlerrm = 'member moved membership without an invite' then raise; end if;
  end;

  begin
    insert into public.workout_events (client_id, pack_id, user_id, occurred_at, sets, reps)
    values (client_event_id, test_pack_id, owner_id, now(), 1, 10);
    raise exception 'cross-member impersonation unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'cross-member impersonation unexpectedly succeeded' then raise; end if;
  end;

  insert into public.workout_events (client_id, pack_id, user_id, occurred_at, sets, reps)
  values (client_event_id, test_pack_id, member_id, now(), 1, 10)
  on conflict (user_id, client_id) do nothing;
  insert into public.workout_events (client_id, pack_id, user_id, occurred_at, sets, reps)
  values (client_event_id, test_pack_id, member_id, now(), 1, 10)
  on conflict (user_id, client_id) do nothing;
  select count(*) into visible_count
  from public.workout_events
  where user_id = member_id and client_id = client_event_id;
  if visible_count <> 1 then raise exception 'duplicate event was not idempotent'; end if;

  begin
    update public.packs set name = 'Member Rename' where id = test_pack_id;
    if found then raise exception 'non-owner updated pack'; end if;
  exception when insufficient_privilege then
    null;
  end;
  reset role;

  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  set local role authenticated;
  update public.packs set name = 'Owner Rename' where id = test_pack_id;
  if not found then raise exception 'owner could not update pack'; end if;
  begin
    update public.pack_members
    set role = 'owner'
    where pack_id = test_pack_id and user_id = member_id;
    raise exception 'owner promoted a second owner';
  exception when others then
    if sqlerrm = 'owner promoted a second owner' then raise; end if;
  end;
  reset role;

  perform private.leave_pack(member_id, test_pack_id);
  if exists (
    select 1 from public.pack_members
    where pack_members.pack_id = test_pack_id and user_id = member_id and status = 'active'
  ) then
    raise exception 'leave did not deactivate membership';
  end if;

  begin
    perform private.delete_pack(member_id, second_pack_id);
    raise exception 'non-owner deleted pack';
  exception when others then
    if sqlerrm = 'non-owner deleted pack' then raise; end if;
  end;
  perform private.delete_pack(owner_id, second_pack_id);
  if exists (select 1 from public.packs where id = second_pack_id) then
    raise exception 'owner delete did not remove pack';
  end if;
end;
$$;

select extensions.pass('social pack authorization and lifecycle checks passed');
select * from extensions.finish();
rollback;
