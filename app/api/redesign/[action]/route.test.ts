import {it,expect,vi,beforeEach} from 'vitest';
const state=vi.hoisted(()=>({rpc:vi.fn(),auth:vi.fn()}));
vi.mock('@/lib/redesign/server',()=>({authenticatedClient:state.auth,portalPrint:vi.fn()}));
vi.mock('@/lib/config/server-env',()=>({serverEnv:()=>({EVENT_SLUG:'duindorp-halloween-2026'}),allowedOrigins:()=>new Set(['https://fixture.invalid'])}));
import {GET,POST} from './route';
const payload={action:'tutorial',role:'house',version:1,index:1,returnPath:'/'};
const request=(value:unknown)=>new Request('https://fixture.invalid/api/redesign/guidance',{method:'POST',headers:{origin:'https://fixture.invalid','content-type':'application/json','x-request-id':'guidance-fixture-1'},body:JSON.stringify(value)});
beforeEach(()=>{state.rpc.mockReset().mockResolvedValue({data:{roles:['house']},error:null});state.auth.mockReset().mockResolvedValue({client:{schema:()=>({rpc:state.rpc})}});});
it('passes a normalized legacy root to the authorized RPC',async()=>{
 expect((await POST(request(payload),{params:Promise.resolve({action:'guidance'})})).status).toBe(200);
 expect(state.rpc.mock.calls[0][1]._payload.returnPath).toBe('/mijn-huis');
});
it.each([['JWT expired','PGRST301',401,'NOT_AUTHORIZED'],['JWT rejected','PGRST303',401,'NOT_AUTHORIZED'],['NOT_AUTHORIZED','42501',403,'NOT_AUTHORIZED'],['INVALID_INPUT','P0001',422,'INVALID_TUTORIAL'],['TUTORIAL_STEP_REQUIRED','P0001',409,'TUTORIAL_STEP_REQUIRED'],['internal sensitive message','XX000',503,'GUIDANCE_UNAVAILABLE']])('maps %s to a safe status',async(message,code,status,publicCode)=>{
 state.rpc.mockResolvedValue({error:{message,code},data:null});
 const response=await POST(request(payload),{params:Promise.resolve({action:'guidance'})});expect(response.status).toBe(status);
 const body=await response.json();expect(body.error.code).toBe(publicCode);expect(body.error.requestId).toBe('guidance-fixture-1');expect(JSON.stringify(body)).not.toContain('sensitive');
});
it('rejects an external destination before the RPC and retains origin protection',async()=>{
 expect((await POST(request({...payload,returnPath:'https://example.invalid'}),{params:Promise.resolve({action:'guidance'})})).status).toBe(422);expect(state.rpc).not.toHaveBeenCalled();
 const invalid=request(payload);invalid.headers.set('origin','https://other.invalid');expect((await POST(invalid,{params:Promise.resolve({action:'guidance'})})).status).toBe(403);
});

it('does not block an authorized intake page with a nonexistent participant tour',async()=>{
 state.rpc.mockResolvedValue({error:{message:'NOT_AUTHORIZED',code:'42501'},data:null});
 const response=await GET(new Request('https://fixture.invalid/api/redesign/guidance'),{params:Promise.resolve({action:'guidance'})});expect(response.status).toBe(204);expect(response.headers.get('cache-control')).toContain('no-store');expect(await response.text()).toBe('');
 expect((await POST(request(payload),{params:Promise.resolve({action:'guidance'})})).status).toBe(403);
});

const closedRequest=(value:unknown)=>new Request('https://fixture.invalid/api/redesign/thanks-closed',{method:'POST',headers:{origin:'https://fixture.invalid','content-type':'application/json'},body:JSON.stringify(value)});
const closedPayload={kind:'all',message:'Bedankt!\nEen eigen toevoeging.',requestKey:'e1000000-0000-4000-8000-000000000001'};
it('stores one server-resolved general thanks with a durable request key',async()=>{
 const response=await POST(closedRequest(closedPayload),{params:Promise.resolve({action:'thanks-closed'})});expect(response.status).toBe(200);
 expect(state.rpc).toHaveBeenCalledWith('portal_thanks_closed_save',{_event_slug:'duindorp-halloween-2026',_kind:'all',_portal_id:null,_choice:null,_message:closedPayload.message,_request_key:closedPayload.requestKey,_submission_id:null});
});
it.each([{...closedPayload,householdId:'e1000000-0000-4000-8000-000000000002'},{...closedPayload,message:'x'.repeat(501)},{...closedPayload,kind:'personal'},{...closedPayload,portalId:'e1000000-0000-4000-8000-000000000002'}])('rejects invalid or client-selected thanks identity before RPC',async value=>{
 expect((await POST(closedRequest(value),{params:Promise.resolve({action:'thanks-closed'})})).status).toBe(422);expect(state.rpc).not.toHaveBeenCalled();
});
it('uses a bounded keyset page and never accepts a client mailbox',async()=>{
 const before='e1000000-0000-4000-8000-000000000001',portal='e1000000-0000-4000-8000-000000000002';
 expect((await GET(new Request(`https://fixture.invalid/api/redesign/thanks-inbox?portalId=${portal}&before=${before}&limit=9999`),{params:Promise.resolve({action:'thanks-inbox'})})).status).toBe(200);
 expect(state.rpc).toHaveBeenCalledWith('portal_thanks_inbox',{_event_slug:'duindorp-halloween-2026',_portal_id:portal,_before:before,_limit:25});
});
it('returns the authorized thanks inbox unchanged with private no-store headers',async()=>{
 const inbox={portalId:'e1000000-0000-4000-8000-000000000002',portalName:'Een poort',total:14,unread:3,counters:{general:14,personal:0,beautiful:0,welcome:0,treats:0},aggregateOnlyCount:11,customMessageCount:3,messages:[],nextCursor:null};
 state.rpc.mockResolvedValue({data:inbox,error:null});
 const response=await GET(new Request(`https://fixture.invalid/api/redesign/thanks-inbox?portalId=${inbox.portalId}`),{params:Promise.resolve({action:'thanks-inbox'})});
 expect(response.status).toBe(200);expect(await response.json()).toEqual(inbox);expect(response.headers.get('cache-control')).toContain('private');expect(response.headers.get('cache-control')).toContain('no-store');
});
it.each(['thanks','thanks-inbox'])('invalidates expired read access for %s rather than reporting an empty inbox',async action=>{
 for(const code of ['PGRST301','PGRST303']){
  state.rpc.mockResolvedValue({data:null,error:{code,message:'expired private token'}});
  const response=await GET(new Request(`https://fixture.invalid/api/redesign/${action}`),{params:Promise.resolve({action})});
  expect(response.status).toBe(401);const body=await response.json();expect(body.error.code).toBe('NOT_AUTHORIZED');expect(JSON.stringify(body)).not.toContain('private token');expect(body.total).toBeUndefined();
 }
});
it('keeps read-status writes origin-protected and authorization failures explicit',async()=>{
 state.rpc.mockResolvedValue({data:null,error:{message:'NOT_AUTHORIZED',code:'42501'}});
 expect((await POST(closedRequest(closedPayload),{params:Promise.resolve({action:'thanks-closed'})})).status).toBe(403);
});
it('does not turn an unknown mutation outcome into success or an automatic retry',async()=>{
 state.rpc.mockResolvedValue({data:null,error:{message:'statement timeout',code:'57014'}});
 const result=await POST(closedRequest(closedPayload),{params:Promise.resolve({action:'thanks-closed'})});expect(result.status).toBe(503);expect((await result.json()).error.code).toBe('THANKS_UNAVAILABLE');expect(state.rpc).toHaveBeenCalledTimes(1);
});
