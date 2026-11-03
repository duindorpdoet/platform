#!/usr/bin/env python3
"""Real serialization error through the new boundary, in an own local DB only.

No network API, Auth server, OTP, mail transport or payment provider is used.
The engine conflict is produced by PostgreSQL REPEATABLE READ and a second
committed writer, rather than a RAISE fixture shaped like an engine message.
"""
import argparse
import json
import re
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--container', default='supabase_db_duindorp_event_close_20261101')
parser.add_argument('--database', required=True)
args = parser.parse_args()
if not args.container.startswith('supabase_db_') or not re.fullmatch(r'frightnight_2027_[a-z0-9_]+', args.database):
    raise SystemExit('Only an explicitly isolated local FrightNight Docker DB is allowed.')
base = ['docker', 'exec', '-i', args.container, 'psql', '-U', 'postgres', '-d', args.database, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']

def sql(query):
    result = subprocess.run(base, input=query, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:])
    lines = [line for line in result.stdout.splitlines() if line.startswith('{') or line.startswith('[')]
    return json.loads(lines[-1]) if lines else None

def literal(value):
    return "'" + str(value).replace("'", "''") + "'"

def command(operation, payload):
    claims = literal(json.dumps({'sub': admin, 'role': 'authenticated'}))
    return sql(f"select set_config('request.jwt.claims',{claims},false);select api.frightnight_command('{slug}',{literal(operation)},{literal(json.dumps(payload))}::jsonb,'{uuid.uuid4()}'::uuid);")

slug = 'frightnight-2027-test-transport-race-' + uuid.uuid4().hex[:10]
admin = str(uuid.uuid4())
sentinel = str(uuid.uuid4())
started = time.monotonic()
protected = sql("select jsonb_build_object('outbox',md5(coalesce((select string_agg(to_jsonb(t)::text,E'\\n'order by to_jsonb(t)::text)from app_private.email_outbox t),'')),'payments',(select count(*)from app_private.payment_requests),'oldAuth',(select count(*)from auth.users));")
sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('{admin}','transport-race-{admin}@example.invalid',now(),'{{}}','{{}}');insert into app_private.events(id,slug,title,local_date,price_cents)values('{sentinel}','transport-sentinel-{sentinel}','Local synthetic transport sentinel','2026-10-31',350);insert into app_private.event_capabilities(event_id,user_id,capability)values('{sentinel}','{admin}','event_admin');select api.frightnight_bootstrap('{slug}','{admin}','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');")
initial = sql(f"select jsonb_build_object('eventId',e.id,'version',f.version)from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug='{slug}';")
event_id = initial['eventId']
claims = literal(json.dumps({'sub': admin, 'role': 'authenticated'}))
transaction = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    # psql flushes the completed SELECT result before accepting the next query.
    transaction.stdin.write(f"\\set VERBOSITY verbose\nbegin isolation level repeatable read;select set_config('request.jwt.claims',{claims},true);select jsonb_build_object('snapshotAcquired',version={initial['version']})from app_private.fn_events where event_id='{event_id}';\n")
    transaction.stdin.flush()
    while True:
        line = transaction.stdout.readline()
        if not line:
            raise RuntimeError('Snapshot session ended before its controlled conflict.')
        if line.startswith('{') and 'snapshotAcquired' in line:
            assert json.loads(line)['snapshotAcquired'], line
            break
    sql(f"update app_private.fn_events set version=version+1 where event_id='{event_id}'and exists(select 1 from app_private.events where id=event_id and slug='{slug}');")
    committed = sql(f"select jsonb_build_object('row',md5(to_jsonb(f)::text),'receipts',(select count(*)from app_private.fn_receipts where event_id=f.event_id),'audits',(select count(*)from app_private.fn_audit where event_id=f.event_id))from app_private.fn_events f where f.event_id='{event_id}';")
    transaction.stdin.write(f"select api.frightnight_command('{slug}','admin.settings','{{\"expectedVersion\":{initial['version']},\"paused\":true}}'::jsonb,'{uuid.uuid4()}'::uuid);commit;\n")
    transaction.stdin.close()
    transaction.wait(timeout=10)
    stderr = transaction.stderr.read()
    assert transaction.returncode != 0 and re.search(r'ERROR:\s+40001:', stderr), 'The genuine engine error was not preserved as40001.'
    assert 'could not serialize access due to concurrent update' in stderr and 'PT409' not in stderr, 'Only the real engine serialization condition is expected.'
    after = sql(f"select jsonb_build_object('row',md5(to_jsonb(f)::text),'receipts',(select count(*)from app_private.fn_receipts where event_id=f.event_id),'audits',(select count(*)from app_private.fn_audit where event_id=f.event_id))from app_private.fn_events f where f.event_id='{event_id}';")
    assert after == committed, 'Aborted serialization transaction changed state or receipts.'
finally:
    if transaction.poll() is None:
        transaction.kill()
        transaction.wait(timeout=5)

# Same stale business condition without an engine snapshot conflict is PT409.
result = sql(f"do $probe$begin perform set_config('request.jwt.claims',{claims},true);begin perform api.frightnight_command('{slug}','admin.settings','{{\"expectedVersion\":{initial['version']},\"paused\":true}}'::jsonb,'{uuid.uuid4()}'::uuid);raise exception 'Expected conflict';exception when sqlstate 'PT409' then if sqlerrm<>'VERSION_CONFLICT'then raise;end if;end;end$probe$;select jsonb_build_object('businessConflict','PT409');")
assert result['businessConflict'] == 'PT409'
current = sql(f"select jsonb_build_object('version',version)from app_private.fn_events where event_id='{event_id}';")
command('admin.settings', {'expectedVersion': current['version'], 'closed': True, 'confirmation': slug, 'reason': 'Own local transport engine race completed; preserve all records'})
end = sql("select jsonb_build_object('outbox',md5(coalesce((select string_agg(to_jsonb(t)::text,E'\\n'order by to_jsonb(t)::text)from app_private.email_outbox t),'')),'payments',(select count(*)from app_private.payment_requests),'oldAuth',(select count(*)from auth.users));")
assert end['outbox'] == protected['outbox'] and end['payments'] == protected['payments'] and end['oldAuth'] == protected['oldAuth'] + 1
print(json.dumps({'passed': True, 'scope': 'isolated-local-postgresql-real-two-transaction-engine-conflict', 'database': args.database, 'genuineEngineSqlstate': '40001', 'genuineEngineMessage': 'could not serialize access due to concurrent update', 'businessSqlstate': 'PT409', 'engineTransactionEffects': 0, 'ownSiblingClosed': True, 'legacyOutboxAndPaymentsUnchanged': True, 'authDeleted': 0, 'externalCalls': 0, 'seconds': round(time.monotonic() - started, 3)}, indent=2))
