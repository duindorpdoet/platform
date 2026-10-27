import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {mailRpc} from './mail-service.mjs';
beforeEach(()=>{vi.stubEnv('SUPABASE_SERVICE_ROLE_KEY','isolated-service-fixture');vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL','https://fixture.supabase.co');});
afterEach(()=>{vi.unstubAllGlobals();vi.unstubAllEnvs();});
describe('deployment RPC response contracts',()=>{
 it('accepts a committed void bootstrap without attempting JSON parsing',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response(null,{status:204})));
  expect(await mailRpc('worker_mail_bootstrap',{_environment:'staging'})).toBeNull();
 });
 it('retains the JSON result for configuration and import RPCs',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue(Response.json({provider:'sendgrid'})));
  expect(await mailRpc('worker_mail_config',{})).toEqual({provider:'sendgrid'});
 });
 it('rejects server failures without exposing response bodies or credentials',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('private-provider-response',{status:500})));
  await expect(mailRpc('worker_mail_bootstrap',{})).rejects.toThrow('MAIL_RPC_worker_mail_bootstrap_500');
 });
});
