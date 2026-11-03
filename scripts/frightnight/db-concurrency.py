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
if not 3 <= args.families <= 30:
    raise SystemExit('Bounded contract test: 3–30 families for the independent join/refund race.')

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
    sql(f"select api.frightnight_entry_grant('{slug}','{actor}',clock_timestamp()+interval '1 hour',repeat('a',64));")
    command(actor, 'registration.save', {'label': f'Concurrent synthetic family {index}', 'routeType': 'lantern', 'adults': 1, 'children': 1, 'maxIntensity': 1})
    order = sql(f"select api.frightnight_payment_create('{slug}','{actor}','{uuid.uuid4()}');")
    sql(f"select api.frightnight_payment_bind('{slug}','{order['order_id']}','ct_{order['order_id']}',null);")
    sql(f"select api.frightnight_payment_confirm('{slug}','ct_{order['order_id']}','paid',{order['amount_cents']},'EUR','race-paid:{order['order_id']}',{literal(json.dumps({'order_id': order['order_id'], 'event_id': order['event_id'], 'testmode': True, 'environment': 'staging'}))}::jsonb);")

with concurrent.futures.ThreadPoolExecutor(max_workers=args.families) as pool:
    snapshots = list(pool.map(lambda actor: command(actor, 'journey.start', {'expectedVersion': 1, 'code': seed['startCode']}), actors))
counts = sql(f"select jsonb_build_object('overbooked',count(*)filter(where occupied>capacity),'active',sum(reservations)) from (select z.id,z.capacity,(app_private.fn_zone_occupancy(z.id)->>'effectivePersons')::integer occupied,count(d.id)reservations from app_private.fn_zones z left join app_private.fn_destinations d on d.zone_id=z.id and d.state='current' where z.event_id=(select id from app_private.events where slug='{slug}') group by z.id) q;")
assert counts['overbooked'] == 0, counts
walking = [(actor, response['snapshot']) for actor, response in zip(actors, snapshots) if response['snapshot']['current']]
waiting = sum(response['snapshot']['journey']['state'] == 'waiting' for response in snapshots)
assert len(walking) == 1 and waiting == args.families - 1, (len(walking), waiting)
actor, snapshot = next(pair for pair in walking if pair[1]['current']['zone']['type'] == 'candy')
current = snapshot['current']
code = next(item['code'] for item in seed['zoneCodes'] if item['zoneId'] == current['zoneId'])
body = {'expectedVersion': snapshot['journey']['version'], 'destinationId': current['id'], 'code': code}
key = str(uuid.uuid4())
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    replay = list(pool.map(lambda _: command(actor, 'journey.complete', body, key), range(2)))
assert replay[0]['result'] == replay[1]['result'], 'Concurrent identical command result replay diverged.'
visits = sql(f"select jsonb_build_object('visits',count(*),'awards',(select count(*) from app_private.fn_awards where award_key='visit:{current['zoneId']}' and registration_id=app_private.fn_registration((select id from app_private.events where slug='{slug}'),'{actor}'))) from app_private.fn_visits where destination_id='{current['id']}';")
assert visits == {'visits': 1, 'awards': 1}, visits
legacy = sql(f"select jsonb_build_object('payments',(select count(*) from app_private.payment_requests pay join app_private.registrations reg on reg.id=pay.registration_id where reg.event_id=(select id from app_private.events where slug='{slug}')),'groups',(select count(*) from app_private.walking_groups where event_id=(select id from app_private.events where slug='{slug}')),'sink',(select count(*) from app_private.fn_mail_sink where event_id=(select id from app_private.events where slug='{slug}')));")
assert legacy['payments'] == 0 and legacy['groups'] == 0 and legacy['sink'] == args.families, legacy
# Payment/refund and scan acquire the same event lock. Either scan is accepted
# before the refund or it is rejected; refunded parties cannot retain a claim.
refund_actor = next(a for a in actors if a != actor)
refund_start = snapshots[actors.index(refund_actor)]['snapshot']
refund_snapshot = command(refund_actor, 'journey.finish', {'expectedVersion': refund_start['journey']['version']})['snapshot']
assert refund_snapshot['current']['zone']['type'] == 'finale', 'An explicit safe return must retain the finale.'
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
old_refund_invitation = command(refund_actor, 'party.invite', {})['result']['token']
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
# An old valid invitation must fail without changing either side after refund.
def membership_digest():
    return sql(f"select jsonb_build_object('digest',md5(jsonb_build_object('members',(select jsonb_agg(to_jsonb(m) order by to_jsonb(m)::text) from app_private.fn_members m where event_id='{refund_order['event_id']}'),'parties',(select jsonb_agg(to_jsonb(p) order by to_jsonb(p)::text) from app_private.fn_parties p where event_id='{refund_order['event_id']}'),'claims',(select jsonb_agg(to_jsonb(d) order by to_jsonb(d)::text) from app_private.fn_destinations d where event_id='{refund_order['event_id']}'),'invites',(select jsonb_agg(to_jsonb(i) order by to_jsonb(i)::text) from app_private.fn_invites i where event_id='{refund_order['event_id']}'),'visits',(select jsonb_agg(to_jsonb(v) order by to_jsonb(v)::text) from app_private.fn_visits v where event_id='{refund_order['event_id']}'),'awards',(select jsonb_agg(to_jsonb(a) order by to_jsonb(a)::text) from app_private.fn_awards a where event_id='{refund_order['event_id']}'))::text));")
before_old_join = membership_digest()
try:
    command(actor, 'party.join', {'token': old_refund_invitation, 'consent': True})
    raise AssertionError('Old invitation reopened a refunded party.')
except RuntimeError as error:
    # If the finale scan won before refund, the target is already finished and
    # the invitation-state guard correctly runs before the member-payment guard.
    finished_refunded_target = sql(f"select jsonb_build_object('finished',state='finished') from app_private.fn_parties where id='{refund_snapshot['journey']['id']}' and event_id='{refund_order['event_id']}';")['finished']
    if 'SAME_PAID_ROUTE_REQUIRED' in str(error):
        old_invitation_denial = 'SAME_PAID_ROUTE_REQUIRED'
    elif refund_scan_outcome == 'accepted-before-refund' and finished_refunded_target and 'INVITATION_INVALID' in str(error):
        old_invitation_denial = 'INVITATION_INVALID_FINISHED_FINALE'
    else:
        raise
assert membership_digest() == before_old_join, 'Rejected invitation changed membership, claims or history.'
# A separate paid target races joining against provider-confirmed refund.
# If joining wins first, the refund must release the entire resulting party.
join_target = next(a for a in actors if a not in [actor, refund_actor])
join_token = command(join_target, 'party.invite', {})['result']['token']
join_order = sql(f"select api.frightnight_payment_for_actor('{slug}','{join_target}');")
def race_join():
    try:
        command(actor, 'party.join', {'token': join_token, 'consent': True})
        return 'joined-before-refund'
    except RuntimeError as error:
        if 'SAME_PAID_ROUTE_REQUIRED' not in str(error):
            raise
        return 'rejected-after-refund'
def race_join_refund():
    metadata = {'order_id': join_order['order_id'], 'event_id': join_order['event_id'], 'testmode': True, 'environment': 'staging'}
    return sql(f"select api.frightnight_payment_confirm('{slug}','{join_order['provider_ref']}','refunded',{join_order['amount_cents']},'EUR','join-race-refund:{join_order['order_id']}',{literal(json.dumps(metadata))}::jsonb);")
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    joined_future = pool.submit(race_join)
    join_refund_future = pool.submit(race_join_refund)
    join_refund_outcome = joined_future.result()
    assert join_refund_future.result()['status'] == 'refunded'
join_refund_integrity = sql(f"select jsonb_build_object('activeClaims',(select count(*) from app_private.fn_destinations where state='current' and party_id=(select party_id from app_private.fn_members where registration_id='{join_order['registration_id']}')),'refundLedger',(select count(*) from app_private.fn_ledger where order_id='{join_order['order_id']}' and kind='refund'),'sourceVisits',(select count(*) from app_private.fn_visits where registration_id=app_private.fn_registration('{join_order['event_id']}','{actor}')));")
assert join_refund_integrity == {'activeClaims': 0, 'refundLedger': 1, 'sourceVisits': 1}, join_refund_integrity
# Checkout and a material edit race for the same event lock. If the edit wins,
# the new larger amount must be quoted; if checkout wins, the edit must fail.
quote_actor = str(uuid.uuid4())
sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{quote_actor}','quote-race-{quote_actor}@example.invalid',now(),'{{}}','{{}}');")
sql(f"select api.frightnight_entry_grant('{slug}','{quote_actor}',clock_timestamp()+interval '1 hour',repeat('b',64));")
command(quote_actor, 'registration.save', {'label': 'Synthetic quote race', 'routeType': 'lantern', 'adults': 1, 'children': 1, 'maxIntensity': 1})
quote_mail_before = sql("select jsonb_build_object('outbox',count(*)) from app_private.email_outbox;")
def race_material_edit():
    try:
        command(quote_actor, 'registration.save', {'label': 'Synthetic quote race', 'routeType': 'lantern', 'adults': 2, 'children': 2, 'maxIntensity': 1})
        return 'edited-before-checkout'
    except RuntimeError as error:
        if 'PAYMENT_QUOTE_LOCKED' not in str(error):
            raise
        return 'rejected-after-checkout'
def race_quote_create():
    return sql(f"select api.frightnight_payment_create('{slug}','{quote_actor}','{uuid.uuid4()}');")
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    edit_future = pool.submit(race_material_edit)
    quote_future = pool.submit(race_quote_create)
    quote_edit_outcome, quote_order = edit_future.result(), quote_future.result()
quote_people = 4 if quote_edit_outcome == 'edited-before-checkout' else 2
assert quote_order['amount_cents'] == quote_people * 350, 'Concurrent checkout quoted an obsolete amount.'
sql(f"select api.frightnight_payment_bind('{slug}','{quote_order['order_id']}','ct_{quote_order['order_id']}',null);")
quote_metadata = {'order_id': quote_order['order_id'], 'event_id': quote_order['event_id'], 'testmode': True, 'environment': 'staging'}
sql(f"select api.frightnight_payment_confirm('{slug}','ct_{quote_order['order_id']}','paid',{quote_order['amount_cents']},'EUR','quote-race-paid:{quote_order['order_id']}',{literal(json.dumps(quote_metadata))}::jsonb);")
quote_after = command(quote_actor, 'notification.read', {'notificationId': str(uuid.uuid4())})['snapshot']['registration']
assert quote_after['persons'] == quote_people and quote_after['amountCents'] == quote_people * 350 and quote_after['status'] == 'active' and quote_after['paymentQuoteLocked'], quote_after
assert quote_mail_before == sql("select jsonb_build_object('outbox',count(*)) from app_private.email_outbox;"), 'Quote race touched legacy mail.'
quote_race_proof = {'families': 1, 'outcome': quote_edit_outcome, 'quotedPersons': quote_people, 'activePersons': quote_after['persons'], 'amountCents': quote_order['amount_cents'], 'pricePerPersonCents': 350, 'freePlaces': 0, 'legacyOutboxUnchanged': True}
# Five physical observation/admission races under the same event lock. Truthful
# observation may report overcapacity AFTER admission; it cannot evict travellers.
# Admission AFTER a full observation must not reserve that zone.
occupancy_races = []
occupancy_actor = next(a for a in actors if a not in [actor, refund_actor, join_target])
occupancy_event = quote_order['event_id']
for iteration in range(5):
    observation_zone = str(uuid.uuid4())
    sql(f"update app_private.fn_zones set status='paused' where event_id='{occupancy_event}' and type<>'finale'; insert into app_private.fn_zones(id,event_id,owner_id,name,address,type,intensity,capacity,status,review_status,opens_at,closes_at,token_hash,run_id,synthetic) select '{observation_zone}',event_id,'{admin}','Physical observation race','Synthetic isolated location','candy',0,2,'open','approved','2027-10-30T15:00Z','2027-10-30T19:00Z',extensions.digest('{observation_zone}','sha256'),run_id,true from app_private.fn_events where event_id='{occupancy_event}'; insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,verified,source) select '{occupancy_event}',a.id,b.id,2,true,'synthetic-fixture' from app_private.fn_zones a join app_private.fn_zones b on b.event_id=a.event_id and b.id<>a.id where a.event_id='{occupancy_event}' and (a.id='{observation_zone}' or b.id='{observation_zone}') on conflict do nothing;")
    before_observation = command(occupancy_actor, 'notification.read', {'notificationId': str(uuid.uuid4())})['snapshot']
    observation_key = str(uuid.uuid4())
    def physical_observation():
        return command(admin, 'zone.occupancy', {'zoneId': observation_zone, 'expectedVersion': 1, 'observedDestinationIds': [], 'extraPersons': 2, 'confirmedUncounted': True}, observation_key)
    def admission():
        return command(occupancy_actor, 'journey.resume', {'expectedVersion': before_observation['journey']['version']})
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        observed_future = pool.submit(physical_observation)
        admitted_future = pool.submit(admission)
        observed_future.result()
        admitted = admitted_future.result()['snapshot']
    admitted_here = admitted['current'] is not None and admitted['current']['zoneId'] == observation_zone
    proof = sql(f"select jsonb_build_object('occupancy',app_private.fn_zone_occupancy('{observation_zone}'),'observationAudit',(select min(id) from app_private.fn_audit where event_id='{occupancy_event}' and action='zone.occupancy.updated' and details->>'commandId'='{observation_key}'),'admissionAudit',(select min(id) from app_private.fn_audit where event_id='{occupancy_event}' and action='route.decision' and details->>'zoneId'='{observation_zone}'),'claimCount',(select count(*) from app_private.fn_destinations where event_id='{occupancy_event}' and zone_id='{observation_zone}' and state='current')); ")
    assert proof['occupancy']['extraPersons'] == 2 and proof['occupancy']['effectivePersons'] == (4 if admitted_here else 2), proof
    assert proof['claimCount'] == (1 if admitted_here else 0), proof
    if admitted_here:
        assert proof['admissionAudit'] < proof['observationAudit'], 'Admission bypassed an earlier physical full observation.'
    occupancy_races.append({'round': iteration + 1, 'order': 'admission-before-observation' if admitted_here else 'observation-blocked-admission', 'appClaims': proof['claimCount'], 'effectivePersons': proof['occupancy']['effectivePersons'], 'truthfulPhysicalOvercapacityRetained': admitted_here, 'newAdmissionAfterPhysicalFull': False})
assert quote_mail_before == sql("select jsonb_build_object('outbox',count(*)) from app_private.email_outbox;"), 'Observation race touched legacy mail.'

# A private-edition entry is checked AFTER acquiring the event lock. Admission
# must not use an entry cached while queued; no enrollment side effect may occur.
entry_queue_races = []
for entry_mode in ['revoked', 'expired']:
    entry_actor = str(uuid.uuid4())
    entry_application = 'fn2027-entry-' + uuid.uuid4().hex
    sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{entry_actor}','entry-race-{entry_actor}@example.invalid',now(),'{{}}','{{}}'); select api.frightnight_entry_grant('{slug}','{entry_actor}',clock_timestamp()+interval '{'2 seconds' if entry_mode == 'expired' else '1 hour'}',repeat('c',64));")
    entry_counts_before = sql(f"select jsonb_build_object('registration',(select count(*) from app_private.fn_registrations where event_id='{occupancy_event}' and owner_id='{entry_actor}'),'household',(select count(*) from app_private.households where primary_contact_user_id='{entry_actor}'),'receipt',(select count(*) from app_private.fn_receipts where event_id='{occupancy_event}' and actor_id='{entry_actor}')); ")
    holder = subprocess.Popen(['docker', 'exec', '-i', args.container, 'psql', '-U', 'postgres', '-d', args.database, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        holder.stdin.write(f"begin; select event_id from app_private.fn_events where event_id='{occupancy_event}' for update; select 'ENTRY_LOCK_READY';\n")
        holder.stdin.flush()
        while holder.stdout.readline().strip() != 'ENTRY_LOCK_READY':
            if holder.poll() is not None:
                raise AssertionError('Entry race event-lock fixture failed.')
        def queued_registration():
            jwt = json.dumps({'sub': entry_actor, 'role': 'authenticated'})
            try:
                sql(f"\\set VERBOSITY verbose\nset application_name={literal(entry_application)}; select set_config('request.jwt.claims',{literal(jwt)},false); select api.frightnight_command('{slug}','registration.save','{{\"label\":\"Queued isolated entry\",\"routeType\":\"lantern\",\"adults\":1,\"children\":0,\"maxIntensity\":1,\"consent\":true,\"termsVersion\":\"2027-test-v1\"}}'::jsonb,'{uuid.uuid4()}');")
                return 'unexpected-enrollment'
            except RuntimeError as error:
                assert '42501' in str(error) and 'EDITION_ACCESS_REQUIRED' in str(error), str(error)
                return '42501:EDITION_ACCESS_REQUIRED'
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            queued = pool.submit(queued_registration)
            for _ in range(100):
                waiting_on_lock = sql(f"select jsonb_build_object('waiting',exists(select 1 from pg_stat_activity where datname=current_database() and application_name='{entry_application}' and wait_event_type='Lock')); ")['waiting']
                if waiting_on_lock:
                    break
                time.sleep(0.02)
            assert waiting_on_lock, 'Entry request did not queue behind the verified event lock.'
            if entry_mode == 'revoked':
                holder.stdin.write(f"delete from app_private.fn_edition_entries where event_id='{occupancy_event}' and user_id='{entry_actor}'; commit;\n")
                holder.stdin.flush()
            else:
                for _ in range(150):
                    expired = sql(f"select jsonb_build_object('expired',expires_at<=clock_timestamp()) from app_private.fn_edition_entries where event_id='{occupancy_event}' and user_id='{entry_actor}';")['expired']
                    if expired:
                        break
                    time.sleep(0.02)
                assert expired, 'Bounded real-time entry fixture did not expire.'
                holder.stdin.write('commit;\n')
                holder.stdin.flush()
            queued_result = queued.result(timeout=20)
        assert queued_result == '42501:EDITION_ACCESS_REQUIRED', queued_result
    finally:
        if holder.poll() is None:
            holder.stdin.write('rollback;\n\\q\n')
            holder.stdin.flush()
        holder.communicate(timeout=10)
    entry_counts_after = sql(f"select jsonb_build_object('registration',(select count(*) from app_private.fn_registrations where event_id='{occupancy_event}' and owner_id='{entry_actor}'),'household',(select count(*) from app_private.households where primary_contact_user_id='{entry_actor}'),'receipt',(select count(*) from app_private.fn_receipts where event_id='{occupancy_event}' and actor_id='{entry_actor}')); ")
    assert entry_counts_before == entry_counts_after == {'registration': 0, 'household': 0, 'receipt': 0}, (entry_counts_before, entry_counts_after)
    entry_queue_races.append({'entry': entry_mode, 'eventLockBarrierVerified': True, 'denial': queued_result, 'registrationsCreated': 0, 'householdsCreated': 0, 'receiptsCreated': 0})

# Reducing an advisory block and requesting its last whole-family checkout use
# the same event lock. A reduction may not discard an authorized PSP hold.
slot_actor = str(uuid.uuid4())
sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('{slot_actor}','slot-race-{slot_actor}@example.invalid',now(),'{{}}','{{}}');select api.frightnight_entry_grant('{slug}','{slot_actor}',clock_timestamp()+interval '1 hour',repeat('d',64));")
command(slot_actor, 'registration.save', {'label': 'Synthetic block capacity race', 'routeType': 'lantern', 'adults': 1, 'children': 1, 'maxIntensity': 1, 'startSlot': '2027-10-30T15:45Z'})
def slot_reduce():
    try:
        command(admin, 'admin.startslot.save', {'startsAt': '2027-10-30T15:45Z', 'capacity': 1})
        return 'reduced-before-checkout'
    except RuntimeError as error:
        assert 'CAPACITY_BELOW_BOOKINGS' in str(error), str(error)
        return 'blocked-by-checkout-hold'
def slot_checkout():
    try:
        sql(f"select api.frightnight_payment_create('{slug}','{slot_actor}','{uuid.uuid4()}');")
        return 'checkout-held-two'
    except RuntimeError as error:
        assert 'START_SLOT_FULL' in str(error), str(error)
        return 'checkout-blocked-by-reduction'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    reduced_future = pool.submit(slot_reduce)
    checkout_future = pool.submit(slot_checkout)
    slot_reduction, slot_checkout_result = reduced_future.result(), checkout_future.result()
slot_after = sql(f"select jsonb_build_object('capacity',capacity,'available',app_private.fn_slot_available(event_id,starts_at,null),'orders',(select count(*) from app_private.fn_orders where event_id='{occupancy_event}' and registration_id=app_private.fn_registration('{occupancy_event}','{slot_actor}'))) from app_private.fn_start_slots where event_id='{occupancy_event}' and starts_at='2027-10-30T15:45Z';")
assert (slot_reduction, slot_checkout_result, slot_after) in [('reduced-before-checkout', 'checkout-blocked-by-reduction', {'capacity': 1, 'available': 1, 'orders': 0}), ('blocked-by-checkout-hold', 'checkout-held-two', {'capacity': 100, 'available': 98, 'orders': 1})], (slot_reduction, slot_checkout_result, slot_after)
slot_capacity_race = {'capacityChange': slot_reduction, 'checkout': slot_checkout_result, **slot_after, 'overbooked': False, 'existingProviderHoldLost': False}

print(json.dumps({'passed': True, 'database': args.database, 'slug': slug, 'families': args.families, 'simultaneousStarts': args.families, 'walking': len(walking), 'waiting': waiting, 'overbooked': 0, 'concurrentReplayRequests': 2, 'visits': 1, 'awards': 1, 'legacyPayments': 0, 'legacyGroups': 0, 'sinkMessages': legacy['sink'], 'concurrentRefundScan': refund_scan_outcome, 'refundedPartyActiveClaims': 0, 'refundLedger': 1, 'distinctRefundRequests': 2, 'fullRefundClaims': 1, 'duplicateRefundRejected': 1, 'alreadyRefundedCreatesIntent': False, 'oldRefundedInvitationRejectedWithoutMutation': True, 'oldRefundedInvitationDenial': old_invitation_denial, 'concurrentJoinRefund': join_refund_outcome, 'joinRefundActiveClaims': 0, 'joinRefundLedger': 1, 'sourceHistoryPreserved': True, 'concurrentCheckoutEdit': quote_race_proof, 'concurrentObservationAdmission': occupancy_races, 'queuedEditionEntry': entry_queue_races, 'concurrentStartCapacityCheckout': slot_capacity_race, 'durationSeconds': round(time.monotonic()-started, 3)}, indent=2))
