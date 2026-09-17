-- Edges are permissions. Only their status may change; identities stay immutable.
create function public.keep_follow_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.follower_id <> old.follower_id or new.followee_id <> old.followee_id then
    raise exception 'follow identities are immutable';
  end if;
  return new;
end $$;
create trigger keep_follow_identity before update on public.follows
for each row execute function public.keep_follow_identity();

-- Cleanup must also work when the *follower* deletes the edge. Their RLS cannot
-- see or delete the owner's close-friends list, so use a narrowly scoped definer.
create or replace function public.drop_close_friend_on_unfollow() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' or new.status <> 'accepted' then
    delete from public.close_friends
    where owner_id = old.followee_id and member_id = old.follower_id;
  end if;
  return null;
end $$;
revoke all on function public.drop_close_friend_on_unfollow() from public;

-- Lock the source edge until close-friend insertion commits. A concurrent
-- unfollow then runs the cleanup after the insertion, leaving no stale grant.
create or replace function public.close_friend_must_follow() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform 1 from public.follows
  where follower_id = new.member_id and followee_id = new.owner_id and status = 'accepted'
  for update;
  if not found then raise exception 'member must be an accepted follower of owner'; end if;
  return new;
end $$;

-- Repair any stale grants left by the old invoker trigger.
delete from public.close_friends c where not exists (
  select 1 from public.follows f
  where f.follower_id = c.member_id and f.followee_id = c.owner_id and f.status = 'accepted'
);

-- Room/channel names are derived from handles; don't allow clients to rename
-- one while issued media tokens and subscriptions still reference it.
create function public.keep_profile_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id <> old.id or new.handle <> old.handle then
    raise exception 'profile identity is immutable';
  end if;
  return new;
end $$;
create trigger keep_profile_identity before update on public.profiles
for each row execute function public.keep_profile_identity();

-- A handle underscore is literal, never a LIKE wildcard.
create or replace function public.search_profiles(q text)
returns table (id uuid, handle text, display_name text, avatar_url text)
language sql security definer stable set search_path = '' as $$
  select p.id, p.handle, p.display_name, p.avatar_url
  from public.profiles p
  where length(regexp_replace(lower(q), '[^a-z0-9_]', '', 'g')) between 2 and 20
    and starts_with(p.handle, regexp_replace(lower(q), '[^a-z0-9_]', '', 'g'))
    and p.id <> auth.uid()
  order by p.handle limit 10
$$;
revoke all on function public.search_profiles(text) from public;
grant execute on function public.search_profiles(text) to authenticated;
