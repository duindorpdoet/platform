#!/usr/bin/env python3
"""Create synthetic browser personas only in the dedicated local Docker DB.

No login delivery, remote server or PSP is accessed. This is not a staging seed.
"""
import json
import subprocess
import uuid

container = 'supabase_db_duindorp_event_close_20261101'
database = 'frightnight_2027_dev'
slug = 'frightnight-2027-test'

def sql(statement):
    r = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], input=statement, text=True, capture_output=True, timeout=30)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    lines = [line for line in r.stdout.splitlines() if line.startswith('{')]
    return json.loads(lines[-1]) if lines else None

def lit(s):
    return "'" + str(s).replace("'", "''") + "'"

def command(actor, operation, payload):
    if operation == 'registration.save':
        payload = {**payload, 'consent': True, 'termsVersion': '2027-test-v1'}
    return sql(f"select set_config('request.jwt.claims',{lit(json.dumps({'sub': actor, 'role': 'authenticated'}))},false);select api.frightnight_command('{slug}',{lit(operation)},{lit(json.dumps(payload))}::jsonb,'{uuid.uuid4()}');")

ids = {key: f'f7270000-0000-0000-0000-{i:012d}' for i, key in enumerate(['admin', 'familyA', 'familyB', 'resident', 'activity', 'finance'], 1)}
for label, uid in ids.items():
    sql(f"insert into auth.users(id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{uid}','authenticated','authenticated','local-{label.lower()}@example.invalid',now(),'{{}}','{{}}') on conflict(id) do nothing;")
legacy = 'f7270000-0000-0000-0000-000000000010'
sql(f"insert into app_private.events(id,slug,title,local_date,price_cents) values('{legacy}','fn-local-browser-protected-2026','Protected local legacy sentinel','2026-10-31',350) on conflict(id) do nothing;insert into app_private.event_capabilities(event_id,user_id,capability) values('{legacy}','{ids['admin']}','event_admin') on conflict do nothing;select api.frightnight_bootstrap('{slug}','{ids['admin']}','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');")
# Schema-only baseline intentionally omits grants; restore only existing API/Storage
# privileges needed by the local gateway. Never grants private table access.
sql('grant usage on schema api to anon,authenticated,service_role; grant usage on schema storage to authenticated,service_role; grant select,insert,delete on storage.objects to authenticated; grant select on storage.buckets to authenticated;')
snapshot = sql(f"select set_config('request.jwt.claims',{lit(json.dumps({'sub': ids['admin'], 'role': 'authenticated'}))},false);select api.frightnight_snapshot('{slug}');")
if snapshot['event']['seedVersion'] == 0:
    command(ids['admin'], 'test.seed', {})
command(ids['admin'], 'test.walk.fixture', {})
for label in ['familyA', 'familyB']:
    command(ids[label], 'registration.save', {'label': 'Testgezin A' if label == 'familyA' else 'Testgezin B', 'routeType': 'lantern', 'adults': 1, 'children': 1, 'maxIntensity': 2 if label == 'familyA' else 1, 'stepFree': True})
    order = sql(f"select api.frightnight_payment_create('{slug}','{ids[label]}','{uuid.uuid4()}');")
    sql(f"select api.frightnight_payment_bind('{slug}','{order['order_id']}','ct_{order['order_id']}',null);")
    sql(f"select api.frightnight_payment_confirm('{slug}','ct_{order['order_id']}','paid',{order['amount_cents']},'EUR','local-paid:{order['order_id']}',{lit(json.dumps({'order_id': order['order_id'], 'event_id': order['event_id'], 'testmode': True, 'environment': 'staging'}))}::jsonb);")
sql(f"insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)select id,'{ids['finance']}','payments_manage','{ids['admin']}' from app_private.events where slug='{slug}' on conflict do nothing;insert into app_private.fn_activity_staff(event_id,activity_id,user_id)select event_id,id,'{ids['activity']}' from app_private.fn_activities where event_id=(select id from app_private.events where slug='{slug}') on conflict do nothing;")
resident = sql(f"select set_config('request.jwt.claims',{lit(json.dumps({'sub': ids['resident'], 'role': 'authenticated'}))},false);select api.frightnight_snapshot('{slug}');")
if not resident['ownZones']:
    command(ids['resident'], 'zone.apply', {'name': 'Testhuis van de Kraaienbode', 'address': 'Synthetisch huis · Duinpad', 'type': 'fright', 'intensity': 2, 'capacity': 8, 'opensAt': '2027-10-30T17:00:00+02:00', 'closesAt': '2027-10-30T21:00:00+02:00', 'stepFree': True, 'description': 'Lokale synthetische bewonersaanmelding voor beoordeling.'})
print(json.dumps({'database': database, 'container': container, 'slug': slug, 'actors': ids, 'testClock': '2027-10-30T17:05:00+02:00', 'paymentProvider': 'contract', 'mailMode': 'sink', 'syntheticWalkFixture': True, 'otpSent': 0, 'externalDelivery': 0}, indent=2))
