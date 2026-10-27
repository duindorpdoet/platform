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
