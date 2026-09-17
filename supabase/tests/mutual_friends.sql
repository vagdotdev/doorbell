-- Run against local Postgres with psql -v ON_ERROR_STOP=1. All fixtures roll back.
begin;
do $$
declare
  alice uuid := gen_random_uuid();
  bob uuid := gen_random_uuid();
  carol uuid := gen_random_uuid();
  refused boolean;
begin
  insert into auth.users (id) values (alice), (bob), (carol);
  insert into public.profiles (id, handle, display_name) values
    (alice, 'qa_' || left(replace(alice::text, '-', ''), 16), 'Alice'),
    (bob, 'qa_' || left(replace(bob::text, '-', ''), 16), 'Bob'),
    (carol, 'qa_' || left(replace(carol::text, '-', ''), 16), 'Carol');
  insert into public.follows values (alice, bob, 'pending', now());

  perform set_config('request.jwt.claim.sub', alice::text, true);
  refused := false;
  begin
    perform public.accept_friend(bob);
  exception when raise_exception then refused := true;
  end;
  if not refused then raise exception 'Requester accepted their own request'; end if;

  perform set_config('request.jwt.claim.sub', carol::text, true);
  refused := false;
  begin
    perform public.accept_friend(alice);
  exception when raise_exception then refused := true;
  end;
  if not refused then raise exception 'Stranger accepted someone else''s request'; end if;

  perform set_config('request.jwt.claim.sub', bob::text, true);
  execute 'set local role authenticated';
  perform public.accept_friend(alice);
  perform public.accept_friend(alice);
  execute 'reset role';
  if (select count(*) from public.follows where follower_id in (alice, bob)
      and followee_id in (alice, bob) and status = 'accepted') <> 2 then
    raise exception 'Acceptance must create exactly two accepted edges';
  end if;
  if exists (select 1 from public.close_friends where owner_id in (alice, bob)) then
    raise exception 'Friendship unexpectedly granted walk-in access';
  end if;

  insert into public.close_friends (owner_id, member_id) values (alice, bob), (bob, alice);
  perform set_config('request.jwt.claim.sub', carol::text, true);
  perform public.remove_friend(alice);
  if (select count(*) from public.follows where follower_id in (alice, bob)
      and followee_id in (alice, bob)) <> 2 then
    raise exception 'Stranger removed someone else''s friendship';
  end if;

  perform set_config('request.jwt.claim.sub', alice::text, true);
  execute 'set local role authenticated';
  perform public.remove_friend(bob);
  execute 'reset role';
  if exists (select 1 from public.follows where follower_id in (alice, bob)
      and followee_id in (alice, bob)) then
    raise exception 'Removal left knocking access behind';
  end if;
  if exists (select 1 from public.close_friends where owner_id in (alice, bob)) then
    raise exception 'Removal left walk-in access behind';
  end if;

  -- Crossed requests settle in one acceptance, with no pending edge left over.
  insert into public.follows (follower_id, followee_id, status) values
    (alice, bob, 'pending'), (bob, alice, 'pending');
  perform public.accept_friend(bob);
  if (select count(*) from public.follows where follower_id in (alice, bob)
      and followee_id in (alice, bob) and status = 'accepted') <> 2 then
    raise exception 'Crossed requests did not settle';
  end if;

  perform set_config('request.jwt.claim.sub', '', true);
  refused := false;
  begin
    perform public.accept_friend(bob);
  exception when raise_exception then refused := true;
  end;
  if not refused then raise exception 'Signed-out caller accepted a request'; end if;
  refused := false;
  begin
    perform public.remove_friend(bob);
  exception when raise_exception then refused := true;
  end;
  if not refused then raise exception 'Signed-out caller removed a friendship'; end if;
  if has_function_privilege('anon', 'public.accept_friend(uuid)', 'EXECUTE')
      or has_function_privilege('anon', 'public.remove_friend(uuid)', 'EXECUTE') then
    raise exception 'Anonymous role can execute friend RPCs';
  end if;
  raise notice 'Mutual friendship checks passed';
end
$$;
rollback;
