-- Doorbell graph: profiles, follows, close friends.
-- Nothing here records presence, knocks, or who saw what. Keep it that way.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null default '',
  avatar_url text,
  created_at timestamptz not null default now()
);

-- follower → followee. Accepted means: follower may knock on followee's door.
create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

-- owner's list. Member may walk into owner's room.
create table public.close_friends (
  owner_id uuid not null references public.profiles (id) on delete cascade,
  member_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, member_id),
  check (owner_id <> member_id)
);

-- A close friend must already be an accepted follower.
create function public.close_friend_must_follow() returns trigger
language plpgsql as $$
begin
  if not exists (
    select 1 from public.follows
    where follower_id = new.member_id and followee_id = new.owner_id and status = 'accepted'
  ) then
    raise exception 'member must be an accepted follower of owner';
  end if;
  return new;
end $$;

create trigger close_friend_must_follow
  before insert on public.close_friends
  for each row execute function public.close_friend_must_follow();

-- Unfollowing (or un-accepting) drops close-friend status too.
create function public.drop_close_friend_on_unfollow() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' or new.status <> 'accepted' then
    delete from public.close_friends
    where owner_id = old.followee_id and member_id = old.follower_id;
  end if;
  return null;
end $$;

create trigger drop_close_friend_on_unfollow
  after delete or update of status on public.follows
  for each row execute function public.drop_close_friend_on_unfollow();

-- Row-level security --------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.follows enable row level security;
alter table public.close_friends enable row level security;

-- Profiles: your own, plus anyone you have a follow edge with (either direction, any status).
create policy "profiles: self and related" on public.profiles for select to authenticated
using (
  id = auth.uid()
  or exists (
    select 1 from public.follows f
    where (f.follower_id = auth.uid() and f.followee_id = profiles.id)
       or (f.followee_id = auth.uid() and f.follower_id = profiles.id)
  )
);
create policy "profiles: insert own" on public.profiles for insert to authenticated
with check (id = auth.uid());
create policy "profiles: update own" on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid());

-- Follows: see edges you're on; request as yourself; only the followee accepts; either side deletes.
create policy "follows: own edges" on public.follows for select to authenticated
using (follower_id = auth.uid() or followee_id = auth.uid());
create policy "follows: request" on public.follows for insert to authenticated
with check (follower_id = auth.uid() and status = 'pending');
create policy "follows: accept" on public.follows for update to authenticated
using (followee_id = auth.uid()) with check (followee_id = auth.uid() and status = 'accepted');
create policy "follows: remove" on public.follows for delete to authenticated
using (follower_id = auth.uid() or followee_id = auth.uid());

-- Close friends: only the owner reads or writes their list. Members are never told.
create policy "close_friends: owner reads" on public.close_friends for select to authenticated
using (owner_id = auth.uid());
create policy "close_friends: owner adds" on public.close_friends for insert to authenticated
with check (owner_id = auth.uid());
create policy "close_friends: owner removes" on public.close_friends for delete to authenticated
using (owner_id = auth.uid());

-- Search ---------------------------------------------------------------------
-- Prefix match on handle. Bypasses the profiles select policy on purpose, but only
-- returns what a search result needs.

create function public.search_profiles(q text)
returns table (id uuid, handle text, display_name text, avatar_url text)
language sql security definer stable
set search_path = public
as $$
  select p.id, p.handle, p.display_name, p.avatar_url
  from public.profiles p
  where length(regexp_replace(lower(q), '[^a-z0-9_]', '', 'g')) >= 2
    and p.handle like regexp_replace(lower(q), '[^a-z0-9_]', '', 'g') || '%'
    and p.id <> auth.uid()
  order by p.handle
  limit 10
$$;

revoke all on function public.search_profiles(text) from public;
grant execute on function public.search_profiles(text) to authenticated;

-- Realtime: the knock signal ---------------------------------------------------
-- Private broadcast channels named door:{handle}. Only the owner may listen. Nobody
-- else has any policy: knocks are sent by the door-token function (service role)
-- after it has checked the graph, so a follower can neither forge a knock nor
-- overhear who else is at a door. Presence is not permitted on any channel.

create policy "door: owner listens" on realtime.messages for select to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and realtime.topic() = 'door:' || p.handle
  )
);
