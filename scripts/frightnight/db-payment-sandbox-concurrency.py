#!/usr/bin/env python3
"""Bounded local-only arm versus first provider-claim race. No network/provider/mail."""
import argparse, concurrent.futures, json, subprocess, uuid
parser=argparse.ArgumentParser()
parser.add_argument('--database',required=True)
parser.add_argument('--container',default='supabase_db_duindorp_event_close_20261101')
a=parser.parse_args()
if not a.database.startswith('frightnight_2027_') or not a.container.startswith('supabase_db_'):
    raise SystemExit('Only an explicit isolated local Docker verification database is allowed.')
def lit(value): return "'"+str(value).replace("'","''")+"'"
def sql(text):
    r=subprocess.run(['docker','exec','-i',a.container,'psql','-U','postgres','-d',a.database,'-X','-q','-A','-t','-v','ON_ERROR_STOP=1'],input=text,text=True,capture_output=True,timeout=30)
    if r.returncode: raise RuntimeError(r.stderr.strip())
    rows=[json.loads(s) for s in r.stdout.splitlines() if s.startswith('{')]
    return rows[-1] if rows else None
before=sql("select jsonb_build_object('outbox',(select count(*)from app_private.email_outbox),'legacyPayments',(select count(*)from app_private.payment_requests),'legacyGroups',(select count(*)from app_private.walking_groups));")
rounds=[]
for i in range(5):
    actor=str(uuid.uuid4()); legacy=str(uuid.uuid4()); slug='frightnight-2027-test-provider-race-'+uuid.uuid4().hex[:10]
    sql(f"insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('{actor}','provider-race-{actor}@example.invalid',now(),'{{}}','{{}}');insert into app_private.events(id,slug,title,local_date,price_cents)values('{legacy}','provider-race-{legacy}','Synthetic local provider-race sentinel','2026-10-31',350);insert into app_private.event_capabilities(event_id,user_id,capability)values('{legacy}','{actor}','event_admin');select api.frightnight_bootstrap('{slug}','{actor}','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');")
    context=sql(f"select jsonb_build_object('eventId',event_id,'runId',run_id)from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='{slug}';")
    def arm():
        try:
            result=sql(f"select api.frightnight_contract_arm('{slug}','{actor}','{context['runId']}','nocteiuvohesvqbowchw:staging:duindorphalloweenstg:{slug}:{context['runId']}');")
            return {'armed':result['armed']}
        except RuntimeError as error:
            reason=next((x for x in ['FRESH_RUN_REQUIRED','MOLLIE_HISTORY_FORBIDDEN'] if x in str(error)),None)
            if reason is None: raise
            return {'denied':reason}
    def claim():
        body={'label':'Synthetic local atomic provider race','routeType':'lantern','adults':1,'children':1,'maxIntensity':1,'consent':True,'termsVersion':'2027-test-v1','startSlot':'2027-10-30T15:00Z'}
        jwt=json.dumps({'sub':actor,'role':'authenticated'})
        return sql(f"begin;select set_config('request.jwt.claims',{lit(jwt)},true);select api.frightnight_command('{slug}','registration.save',{lit(json.dumps(body))}::jsonb,'{uuid.uuid4()}');select api.frightnight_payment_claim('{slug}','{actor}','{uuid.uuid4()}','mollie');commit;")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        ar=pool.submit(arm); cl=pool.submit(claim); armed=ar.result(); order=cl.result()
    state=sql(f"select jsonb_build_object('policy',payment_policy,'runId',run_id,'sandboxRunId',contract_run_id,'orders',(select count(*)from app_private.fn_orders where event_id=f.event_id),'claims',(select count(*)from app_private.fn_orders where event_id=f.event_id and provider_claimed_at is not null))from app_private.fn_events f where event_id='{context['eventId']}';")
    assert order['provider_claimed'] is True and state['orders']==state['claims']==1,(armed,order,state)
    if armed.get('armed'):
        assert state['policy']=='contract_sandbox' and order['provider']=='contract' and state['runId']==state['sandboxRunId'],(armed,order,state)
    else:
        assert state['policy']=='configured' and order['provider']=='mollie',(armed,order,state)
    rounds.append({'round':i+1,'arm':armed,'provider':order['provider'],'orders':1,'durableClaims':1,'externalCalls':0})
after=sql("select jsonb_build_object('outbox',(select count(*)from app_private.email_outbox),'legacyPayments',(select count(*)from app_private.payment_requests),'legacyGroups',(select count(*)from app_private.walking_groups));")
assert before==after,(before,after)
print(json.dumps({'passed':True,'scope':'isolated-local-docker','database':a.database,'rounds':rounds,'protectedLegacyUnchanged':True,'externalCalls':0,'otp':0,'mail':0}))
