import {createHash} from 'node:crypto';
import {describe,it,expect,vi} from 'vitest';
import {stagingAuthPolicy} from './preserve-staging-auth.mjs';
import {UPDATES_HTML_BRANCH} from './staging-installed-history.mjs';

const recipients='tester-a@example.invalid,tester-b@example.invalid,owner@example.invalid';
const env={GITHUB_REPOSITORY:'duindorpdoet/platform',GITHUB_REF:`refs/heads/${UPDATES_HTML_BRANCH}`,GITHUB_SHA:'a'.repeat(40),
  APP_ENVIRONMENT:'staging',SUPABASE_PROJECT_REF:'nocteiuvohesvqbowchw',SUPABASE_ACCESS_TOKEN:'test-only',
  FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:recipients,TEST_EMAIL_1:'tester-a@example.invalid',TEST_EMAIL_2:'tester-b@example.invalid'};
const secrets=()=>Object.entries({APP_ENVIRONMENT:'staging',AUTH_MAIL_MODE:'allowlist',FRIGHTNIGHT_ENABLED:'true',FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:recipients})
  .map(([name,value])=>({name,value:createHash('sha256').update(value).digest('hex')}));
function transport(version=42,rows=secrets()) {
  return vi.fn<typeof fetch>(async input=>new Response(JSON.stringify(String(input).endsWith('/secrets')?rows:
    {slug:'send-email-hook',status:'ACTIVE',verify_jwt:false,version})));
}
describe('preserved staging Auth policy for the isolated HTML hotfix',()=>{
  it('proves actual deployed allowlist digests and exact unchanged function through GET metadata only',async()=>{
    const request=transport();const result=await stagingAuthPolicy({...env,EXPECTED_STAGING_AUTH_FUNCTION_VERSION:'42'},request);
    expect(result).toMatchObject({functionVersion:42,matchedPolicyDigests:4,allowlistedRecipients:3,authenticationRequests:0,mailDelivery:0,secretMutations:0,readOnly:true});
    expect(request).toHaveBeenCalledTimes(2);
    for(const [url,options]of request.mock.calls){expect(String(url)).toMatch(/^https:\/\/api\.supabase\.com\/v1\/projects\/nocteiuvohesvqbowchw\//);expect(options?.method).toBe('GET');expect(options?.body).toBeUndefined();}
    expect(JSON.stringify(result)).not.toContain('@');expect(JSON.stringify(result)).not.toContain('test-only');
  });
  it.each([{APP_ENVIRONMENT:'production'},{SUPABASE_PROJECT_REF:'dtubngvxfbupgvgfrjko'},{GITHUB_REF:'refs/heads/staging'},{GITHUB_SHA:'other'},{SUPABASE_ACCESS_TOKEN:''}])('rejects another context before any remote request: %j',async patch=>{
    const request=transport();await expect(stagingAuthPolicy({...env,...patch},request)).rejects.toThrow('STAGING_AUTH_PRESERVATION_BOUNDARY');expect(request).not.toHaveBeenCalled();
  });
  it('rejects a changed/missing tester allowlist before any remote request',async()=>{
    const request=transport();await expect(stagingAuthPolicy({...env,FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'other@example.invalid'},request)).rejects.toThrow('STAGING_AUTH_ALLOWLIST_BINDING_REQUIRED');expect(request).not.toHaveBeenCalled();
  });
  it.each(['APP_ENVIRONMENT','AUTH_MAIL_MODE','FRIGHTNIGHT_ENABLED','FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS'])('fails closed if the actual deployed %s digest differs',async name=>{
    const rows=secrets();rows.find(row=>row.name===name)!.value='0'.repeat(64);await expect(stagingAuthPolicy(env,transport(42,rows))).rejects.toThrow('STAGING_AUTH_DEPLOYED_POLICY_MISMATCH');
  });
  it('rejects a replaced function and rejects raw secret values rather than logging them',async()=>{
    await expect(stagingAuthPolicy({...env,EXPECTED_STAGING_AUTH_FUNCTION_VERSION:'41'},transport())).rejects.toThrow('STAGING_AUTH_FUNCTION_CHANGED');
    const rows=secrets();rows[0].value='PRIVATE_VALUE';await expect(stagingAuthPolicy(env,transport(42,rows))).rejects.toThrow('STAGING_AUTH_DEPLOYED_POLICY_MISMATCH');
  });
});
