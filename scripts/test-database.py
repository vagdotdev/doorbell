#!/usr/bin/env python3
"""Run migrations and hostile-role probes in an isolated database, never the app DB."""
import pathlib, subprocess, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_Doorbell'
name = 'doorbell_test_' + uuid.uuid4().hex[:12]
def sql(text, db=name):
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', db], input=text, text=True, capture_output=True, check=True).stdout
try:
    sql(f'CREATE DATABASE {name};', 'postgres')
    sql('''
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE SCHEMA realtime;
CREATE TABLE realtime.messages(extension text);
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION realtime.topic() RETURNS text LANGUAGE sql STABLE AS $$ SELECT current_setting('realtime.topic',true) $$;
GRANT USAGE ON SCHEMA public,auth,realtime TO authenticated,anon,service_role;
GRANT EXECUTE ON FUNCTION auth.uid(),realtime.topic() TO authenticated,anon,service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO authenticated,anon,service_role;
''')
    for migration in sorted((ROOT/'supabase/migrations').glob('*.sql')): sql(migration.read_text())
    sql('''
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002'),('00000000-0000-0000-0000-000000000003');
INSERT INTO public.profiles(id,handle) SELECT id, CASE right(id::text,1) WHEN '1' THEN 'alice' WHEN '2' THEN 'owner' ELSE 'stranger' END FROM auth.users;
INSERT INTO public.follows VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','accepted',now());
INSERT INTO public.close_friends VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',now());
''')
    def as_user(suffix, query):
        return sql(f"SET ROLE authenticated; SET request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000{suffix}'; " + query)
    def denied(query):
        try: as_user(1,query)
        except subprocess.CalledProcessError as e:
            assert 'permission denied' in e.stderr or 'row-level security' in e.stderr, e.stderr
            return
        raise AssertionError('Expected access denial: '+query)
    # Read attempts return no unrelated rows; close-friend membership is hidden from the member.
    out=as_user(3, "DO $$ BEGIN IF (SELECT count(*) FROM public.follows) <> 0 THEN RAISE EXCEPTION 'graph leak'; END IF; END $$;")
    as_user(1, "DO $$ BEGIN IF (SELECT count(*) FROM public.close_friends) <> 0 THEN RAISE EXCEPTION 'close-list leak'; END IF; END $$;")
    denied("UPDATE public.profiles SET handle='stolen' WHERE handle='alice';")
    denied("UPDATE public.follows SET follower_id='00000000-0000-0000-0000-000000000003';")
    denied("SELECT public.consume_door_request('00000000-0000-0000-0000-000000000001');")
    denied("SELECT * FROM private.door_request_limits;")
    denied("INSERT INTO public.follows(follower_id,followee_id,status) VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003','accepted');")
    as_user(1,"DELETE FROM public.follows WHERE follower_id=auth.uid();")
    sql("DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.close_friends) THEN RAISE EXCEPTION 'stale close permission after follower deletes'; END IF; END $$;")
    sql("SET ROLE service_role; DO $$ BEGIN FOR i IN 1..30 LOOP IF NOT public.consume_door_request('00000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'early limit'; END IF; END LOOP; IF public.consume_door_request('00000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'missing limit'; END IF; END $$;")
    print('PASS: migrations; hidden graph; hidden close list; immutable handle/edge; private rate limits; no self-accept; follower-side cleanup; 30-request cap')
except subprocess.CalledProcessError as e:
    print(e.stderr)
    raise
finally:
    sql(f'DROP DATABASE IF EXISTS {name} WITH (FORCE);', 'postgres')
