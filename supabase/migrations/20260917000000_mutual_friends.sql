-- One accepted request lets both friends knock. Existing edges are preserved;
-- close-friend / walk-in grants remain individual choices.
create function public.accept_friend(p_profile_id uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if me = p_profile_id then raise exception 'That is you.'; end if;

  -- Crossed requests share a lock, avoiding opposite-order row locks.
  perform pg_advisory_xact_lock(hashtextextended(
    least(me::text, p_profile_id::text) || ':' || greatest(me::text, p_profile_id::text), 0));

  if not exists (
    select 1 from public.follows where follower_id = p_profile_id and followee_id = me
  ) then raise exception 'No request from them.'; end if;

  update public.follows set status = 'accepted'
    where follower_id = p_profile_id and followee_id = me;
  insert into public.follows (follower_id, followee_id, status)
    values (me, p_profile_id, 'accepted')
    on conflict (follower_id, followee_id) do update set status = 'accepted';
end
$$;

create function public.remove_friend(p_profile_id uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(
    least(me::text, p_profile_id::text) || ':' || greatest(me::text, p_profile_id::text), 0));
  -- Existing delete triggers revoke walk-in permissions in both directions.
  delete from public.follows
    where (follower_id = me and followee_id = p_profile_id)
       or (follower_id = p_profile_id and followee_id = me);
end
$$;

revoke all on function public.accept_friend(uuid) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
grant execute on function public.accept_friend(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
