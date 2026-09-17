#!/bin/bash
# Run against the existing local Supabase, in a transaction that always rolls back.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import subprocess
from pathlib import Path
migration = Path('supabase/migrations/20260915160000_graph_integrity.sql').read_text()
# Permit this regression probe both before and after applying the migration.
check = subprocess.run(['docker','exec','supabase_db_Doorbell','psql','-U','postgres','-d','postgres','-Atc',
    "select count(*) from pg_trigger where tgname = 'keep_follow_identity'"], capture_output=True, text=True, check=True)
setup = migration if check.stdout.strip() == '0' else ''
sql = "BEGIN;\n" + setup + r'''
insert into auth.users(id, email) values
 ('10000000-0000-0000-0000-000000000001','graph-qa-1@example.invalid'),
 ('10000000-0000-0000-0000-000000000002','graph-qa-2@example.invalid'),
 ('10000000-0000-0000-0000-000000000003','graph-qa-3@example.invalid');
insert into public.profiles(id, handle, display_name) values
 ('10000000-0000-0000-0000-000000000001','graph_qa_owner','Owner'),
 ('10000000-0000-0000-0000-000000000002','graph_qa_follower','Follower'),
 ('10000000-0000-0000-0000-000000000003','graph_qa_other','Other');
insert into public.follows(follower_id,followee_id,status) values
 ('10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','accepted');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
insert into public.close_friends(owner_id,member_id) values
 ('10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002');
do $$ begin
  begin
    update public.follows set follower_id='10000000-0000-0000-0000-000000000003'
      where followee_id='10000000-0000-0000-0000-000000000001';
    raise exception 'TEST FAILED: follower identity rewrite succeeded';
  exception when raise_exception then
    if sqlerrm <> 'follow identities are immutable' then raise; end if;
  end;
  begin
    update public.profiles set handle='changed_handle' where id=auth.uid();
    raise exception 'TEST FAILED: handle mutation succeeded';
  exception when raise_exception then
    if sqlerrm <> 'profile identity is immutable' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
do $$ begin
  if exists(select 1 from public.close_friends) then raise exception 'TEST FAILED: follower can see owner close list'; end if;
end $$;
delete from public.follows where follower_id=auth.uid();
reset role;
do $$ begin
  if exists(select 1 from public.close_friends where owner_id='10000000-0000-0000-0000-000000000001') then
    raise exception 'TEST FAILED: walk-in grant survived unfollow';
  end if;
end $$;
ROLLBACK;
'''
result = subprocess.run(['docker','exec','-i','supabase_db_Doorbell','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],input=sql,text=True,capture_output=True)
print(result.stdout)
print(result.stderr)
if result.returncode: raise SystemExit(result.returncode)
print('PASS: edge identities, handle identity, private close list, follower-side revocation; transaction rolled back.')
PY
