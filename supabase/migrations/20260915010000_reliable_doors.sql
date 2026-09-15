-- Preserve permission invariants regardless of which side removes a follow.
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

-- An accept updates status only; identity columns are not editable.
revoke update on public.follows from authenticated;
grant update (status) on public.follows to authenticated;
-- Handles currently name LiveKit rooms. Keep them immutable until ID-based rename is implemented.
revoke update on public.profiles from authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;

-- A short-lived per-account request bucket, not a door or knock history.
create schema if not exists private;
create table private.door_request_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  requests integer not null
);
alter table private.door_request_limits enable row level security;
revoke all on private.door_request_limits from public, anon, authenticated;
create function public.consume_door_request(caller uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare used integer;
begin
  -- Opportunistic expiry; at most one row per account, no accumulated event log.
  delete from private.door_request_limits where window_start < now() - interval '2 minutes';
  insert into private.door_request_limits as limits(user_id, window_start, requests)
  values(caller, now(), 1)
  on conflict (user_id) do update set
    requests = case when limits.window_start < now() - interval '1 minute' then 1 else limits.requests + 1 end,
    window_start = case when limits.window_start < now() - interval '1 minute' then now() else limits.window_start end
  returning requests into used;
  return used <= 30;
end $$;
revoke all on function public.consume_door_request(uuid) from public, anon, authenticated;
grant execute on function public.consume_door_request(uuid) to service_role;
