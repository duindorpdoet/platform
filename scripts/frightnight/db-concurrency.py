#!/usr/bin/env python3
"""Deterministic SQL contract race. Only an explicitly named local Docker DB.

No OTP, provider calls, email dispatch or remote connection is possible here.
Requires the current migration and a schema-compatible local verification DB.
"""
import argparse
import concurrent.futures
import json
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--container', default='supabase_db_duindorp_event_close_20261101')
parser.add_argument('--database', default='frightnight_2027_dev')
parser.add_argument('--families', type=int, default=12)
args = parser.parse_args()
if not args.container.startswith('supabase_db_') or not args.database.startswith('frightnight_2027_'):
    raise SystemExit('Only the explicitly isolated local FrightNight verification database is allowed.')
if not 2 <= args.families <= 30:
    raise SystemExit('Bounded contract test: 2–30 families.')

def sql(statement):
    result = subprocess.run(['docker', 'exec', '-i', args.container, 'psql', '-U', 'postgres', '-d', args.database, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], input=statement, text=True, capture_output=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    lines = [line for line in result.stdout.splitlines() if line.startswith('{') or line.startswith('[')]
    return json.loads(lines[-1]) if lines else None

def literal(value):
    return "'" + str(value).replace("'", "''") + "'"

def command(actor, operation, payload, key=None):
    if operation == 'registration.save':
        payload = {**payload, 'consent': True, 'termsVersion': '2027-test-v1'}
    jwt = json.dumps({'sub': actor, 'role': 'authenticated'})
    return sql(f"select set_config('request.jwt.claims',{literal(jwt)},false); select api.frightnight_command({literal(slug)},{literal(operation)},{literal(json.dumps(payload))}::jsonb,{literal(key or uuid.uuid4())}::uuid);")

admin = str(uuid.uuid4())
legacy = str(uuid.uuid4())
slug = 'frightnight-2027-test-race-' + uuid.uuid4().hex[:12]
started = time.monotonic()
sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{admin}','race-admin-{admin}@example.invalid',now(),'{{}}','{{}}'); insert into app_private.events(id,slug,title,local_date,price_cents) values('{legacy}','race-legacy-{legacy}','Isolated local legacy sentinel','2026-10-31',350); insert into app_private.event_capabilities(event_id,user_id,capability)values('{legacy}','{admin}','event_admin'); select api.frightnight_bootstrap('{slug}','{admin}','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');")
seed = command(admin, 'test.seed', {})['result']
command(admin, 'test.walk.fixture', {})
# Explicitly controlled synthetic capacity race; no real walking-path claim.
sql(f"update app_private.fn_zones set capacity=2,status=case when type in('candy','finale') then 'open' else 'paused' end where event_id=(select id from app_private.events where slug='{slug}');")
actors = [str(uuid.uuid4()) for _ in range(args.families)]
for index, actor in enumerate(actors):
    sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{actor}','race-{actor}@example.invalid',now(),'{{}}','{{}}');")
    command(actor, 'registration.save', {'label': f'Concurrent synthetic family {index}', 'routeType': 'lantern', 'adults': 1, 'children': 1, 'maxIntensity': 1})
    order = sql(f"select api.frightnight_payment_create('{slug}','{actor}','{uuid.uuid4()}');")
    sql(f"select api.frightnight_payment_bind('{slug}','{order['order_id']}','ct_{order['order_id']}',null);")
    sql(f"select api.frightnight_payment_confirm('{slug}','ct_{order['order_id']}','paid',{order['amount_cents']},'EUR','race-paid:{order['order_id']}',{literal(json.dumps({'order_id': order['order_id'], 'event_id': order['event_id'], 'testmode': True, 'environment': 'staging'}))}::jsonb);")

with concurrent.futures.ThreadPoolExecutor(max_workers=args.families) as pool:
    snapshots = list(pool.map(lambda actor: command(actor, 'journey.start', {'expectedVersion': 1, 'code': seed['startCode']}), actors))
counts = sql(f"select jsonb_build_object('overbooked',count(*)filter(where occupied>capacity),'active',sum(reservations)) from (select z.id,z.capacity,coalesce(sum(d.persons),0)occupied,count(d.id)reservations from app_private.fn_zones z left join app_private.fn_destinations d on d.zone_id=z.id and d.state='current' where z.event_id=(select id from app_private.events where slug='{slug}') group by z.id) q;")
assert counts['overbooked'] == 0, counts
walking = [(actor, response['snapshot']) for actor, response in zip(actors, snapshots) if response['snapshot']['current']]
waiting = sum(response['snapshot']['journey']['state'] == 'waiting' for response in snapshots)
assert len(walking) == 2 and waiting == args.families - 2, (len(walking), waiting)
actor, snapshot = next(pair for pair in walking if pair[1]['current']['zone']['type'] == 'candy')
current = snapshot['current']
code = next(item['code'] for item in seed['zoneCodes'] if item['zoneId'] == current['zoneId'])
body = {'expectedVersion': snapshot['journey']['version'], 'destinationId': current['id'], 'code': code}
key = str(uuid.uuid4())
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    replay = list(pool.map(lambda _: command(actor, 'journey.complete', body, key), range(2)))
assert replay[0] == replay[1], 'Concurrent identical command replay diverged.'
visits = sql(f"select jsonb_build_object('visits',count(*),'awards',(select count(*) from app_private.fn_awards where award_key='visit:{current['zoneId']}' and registration_id=app_private.fn_registration((select id from app_private.events where slug='{slug}'),'{actor}'))) from app_private.fn_visits where destination_id='{current['id']}';")
assert visits == {'visits': 1, 'awards': 1}, visits
legacy = sql(f"select jsonb_build_object('payments',(select count(*) from app_private.payment_requests pay join app_private.registrations reg on reg.id=pay.registration_id where reg.event_id=(select id from app_private.events where slug='{slug}')),'groups',(select count(*) from app_private.walking_groups where event_id=(select id from app_private.events where slug='{slug}')),'sink',(select count(*) from app_private.fn_mail_sink where event_id=(select id from app_private.events where slug='{slug}')));")
assert legacy['payments'] == 0 and legacy['groups'] == 0 and legacy['sink'] == args.families, legacy
# Payment/refund and scan acquire the same event lock. Either scan is accepted
# before the refund or it is rejected; refunded parties cannot retain a claim.
refund_actor, refund_snapshot = next(pair for pair in walking if pair[1]['current']['zone']['type'] == 'finale')
refund_order = sql(f"select api.frightnight_payment_for_actor('{slug}','{refund_actor}');")
# Distinct command IDs must acquire one durable full-refund intent before any
# external provider call. No provider is contacted by this contract probe.
def claim_refund(_):
    try:
        sql(f"select api.frightnight_payment_for_refund('{slug}','{admin}','{refund_order['registration_id']}','{uuid.uuid4()}','Synthetic concurrent full refund');")
        return 'claimed'
    except RuntimeError as error:
        if 'REFUND_ALREADY_REQUESTED' not in str(error):
            raise
        return 'rejected'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    refund_claims = list(pool.map(claim_refund, range(2)))
assert sorted(refund_claims) == ['claimed', 'rejected'], refund_claims
claim_count = sql(f"select jsonb_build_object('claims',count(*)) from app_private.fn_refunds where event_id='{refund_order['event_id']}' and order_id='{refund_order['order_id']}';")
assert claim_count['claims'] == 1, claim_count
refund_current = refund_snapshot['current']
refund_code = next(item['code'] for item in seed['zoneCodes'] if item['zoneId'] == refund_current['zoneId'])
def race_scan():
    try:
        command(refund_actor, 'journey.complete', {'expectedVersion': refund_snapshot['journey']['version'], 'destinationId': refund_current['id'], 'code': refund_code})
        return 'accepted-before-refund'
    except RuntimeError as error:
        if 'PAID_REGISTRATION_REQUIRED' not in str(error):
            raise
        return 'rejected-after-refund'
def race_refund():
    metadata = {'order_id': refund_order['order_id'], 'event_id': refund_order['event_id'], 'testmode': True, 'environment': 'staging'}
    return sql(f"select api.frightnight_payment_confirm('{slug}','{refund_order['provider_ref']}','refunded',{refund_order['amount_cents']},'EUR','race-refund:{refund_order['order_id']}',{literal(json.dumps(metadata))}::jsonb);")
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    scan_future = pool.submit(race_scan)
    refund_future = pool.submit(race_refund)
    refund_scan_outcome = scan_future.result()
    refunded = refund_future.result()
assert refunded['status'] == 'refunded', refunded
refunded_retry = sql(f"select api.frightnight_payment_for_refund('{slug}','{admin}','{refund_order['registration_id']}','{uuid.uuid4()}','Already refunded must not create a new claim');")
assert refunded_retry['status'] == 'refunded', refunded_retry
assert sql(f"select jsonb_build_object('claims',count(*)) from app_private.fn_refunds where event_id='{refund_order['event_id']}' and order_id='{refund_order['order_id']}';")['claims'] == 1

refund_integrity = sql(f"select jsonb_build_object('activeClaims',(select count(*) from app_private.fn_destinations where party_id='{refund_snapshot['journey']['id']}' and state='current'),'refundLedger',(select count(*) from app_private.fn_ledger where order_id='{refund_order['order_id']}' and kind='refund'),'visits',(select count(*) from app_private.fn_visits where destination_id='{refund_current['id']}'));")
assert refund_integrity['activeClaims'] == 0 and refund_integrity['refundLedger'] == 1 and refund_integrity['visits'] <= 1, refund_integrity
print(json.dumps({'passed': True, 'database': args.database, 'slug': slug, 'families': args.families, 'simultaneousStarts': args.families, 'walking': len(walking), 'waiting': waiting, 'overbooked': 0, 'concurrentReplayRequests': 2, 'visits': 1, 'awards': 1, 'legacyPayments': 0, 'legacyGroups': 0, 'sinkMessages': legacy['sink'], 'concurrentRefundScan': refund_scan_outcome, 'refundedPartyActiveClaims': 0, 'refundLedger': 1, 'distinctRefundRequests': 2, 'fullRefundClaims': 1, 'duplicateRefundRejected': 1, 'alreadyRefundedCreatesIntent': False, 'durationSeconds': round(time.monotonic()-started, 3)}, indent=2))
