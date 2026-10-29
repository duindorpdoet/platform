import {beforeEach,describe,it,expect,vi} from 'vitest';
const mock=vi.hoisted(()=>({exchange:vi.fn(),create:vi.fn(),child:vi.fn()}));
vi.mock('@supabase/ssr',async importOriginal=>({...await importOriginal<typeof import('@supabase/ssr')>(),createServerClient:mock.create}));
vi.mock('@/lib/config/public-env',()=>({getPublicSupabaseConfig:()=>({url:'https://project.supabase.co',publishableKey:'public-fixture'})}));
vi.mock('@/lib/config/server-env',()=>({serverEnv:()=>({APP_URL:'https://app.invalid'})}));
vi.mock('@/lib/poortenboek/server',()=>({CHILD_COOKIE:'__Host-poortenboek-session',DEMO_COOKIE:'__Host-poortenboek-demo',cookieOptions:{path:'/',secure:true,httpOnly:true,sameSite:'lax'},childRpc:mock.child}));
vi.mock('@/lib/poortenboek/crypto',()=>({tokenHash:()=> 'hashed-previous-child-fixture'}));
import {GET} from './route';
import {registrationActivationReturnPath} from '@/lib/auth/registration-activation';
beforeEach(()=>{mock.exchange.mockReset();mock.create.mockReset();mock.child.mockReset();mock.child.mockResolvedValue({ok:true});mock.create.mockImplementation((_url,_key,options)=>{
 expect(options.cookies.getAll()).toEqual(expect.arrayContaining([{name:'sb-project-auth-token-code-verifier',value:'pkce-fixture'}]));
 options.cookies.setAll([{name:'sb-project-auth-token.0',value:'session-part-one',options:{maxAge:31536000,secure:true}},{name:'sb-project-auth-token.1',value:'session-part-two',options:{maxAge:31536000,secure:true}},{name:'sb-project-auth-token-code-verifier',value:'',options:{maxAge:0}}]);
 return {auth:{exchangeCodeForSession:mock.exchange}};
});});
const headers={cookie:'sb-project-auth-token-code-verifier=pkce-fixture; poorten-remember=0; poorten-auth-next=%2Fomgeving%2Fkiezen'};
describe('real PKCE callback contract using an isolated auth adapter',()=>{
 it('returns a verified Google login to the common registration claim step without activating from a stale cookie',async()=>{
  const next=registrationActivationReturnPath('b'.repeat(64));
  mock.exchange.mockResolvedValue({error:null,data:{session:{},user:{id:'verified-invited-parent'}}});
  const response=await GET(new Request('https://app.invalid/auth/callback?code=invitation-fixture',{headers:{cookie:'sb-project-auth-token-code-verifier=pkce-fixture; poorten-auth-next='+encodeURIComponent(next)}}));
  expect(response.headers.get('location')).toBe('https://app.invalid'+next);
  expect(response.headers.get('cache-control')).toContain('no-store');
  expect(response.cookies.get('poorten-auth-next')?.maxAge).toBe(0);
 });
 it('passes the verifier and preserves all cookie chunks/deletions on success',async()=>{
  mock.exchange.mockResolvedValue({error:null,data:{session:{},user:{id:'verified'}}});
  const r=await GET(new Request('https://app.invalid/auth/callback?code=single-use-fixture',{headers}));
  expect(mock.exchange).toHaveBeenCalledWith('single-use-fixture');
  expect(r.headers.get('location')).toBe('https://app.invalid/omgeving/kiezen');
  expect(r.headers.get('cache-control')).toContain('no-store');
  expect(r.headers.getSetCookie()).toHaveLength(6);
  expect(r.cookies.get('sb-project-auth-token.0')?.value).toBe('session-part-one');
  expect(r.cookies.get('sb-project-auth-token.1')?.value).toBe('session-part-two');
  expect(r.headers.getSetCookie().find(c=>c.startsWith('sb-project-auth-token.0='))).not.toContain('Max-Age');
 });
 it('uses the trusted public origin behind the deployment proxy',async()=>{
  mock.exchange.mockResolvedValue({error:null,data:{session:{},user:{id:'verified'}}});
  const r=await GET(new Request('http://internal-server:3100/auth/callback?code=fixture',{headers}));
  expect(r.headers.get('location')).toBe('https://app.invalid/omgeving/kiezen');
 });
 it('does not accept an exchange without a confirmed user and session',async()=>{
  mock.exchange.mockResolvedValue({error:null,data:{session:null,user:null}});
  const r=await GET(new Request('https://app.invalid/auth/callback?code=expired&next=//evil.invalid',{headers}));
  expect(r.headers.get('location')).toBe('https://app.invalid/inloggen?error=callback&next=%2Fomgeving%2Fkiezen');
 });
 it('returns cancellation to the complete login screen without an exchange',async()=>{
  const r=await GET(new Request('https://app.invalid/auth/callback?error=access_denied',{headers}));
  expect(mock.exchange).not.toHaveBeenCalled();
  expect(r.headers.get('location')).toContain('error=google_cancelled');
 });
 it('contains temporary failures without logging credentials or granting access',async()=>{
  mock.exchange.mockRejectedValue(new Error('network'));
  const r=await GET(new Request('https://app.invalid/auth/callback?code=fixture',{headers}));
  expect(r.headers.get('location')).toContain('/inloggen?error=callback');
 });
});

it('confirmed adult OAuth clears and revokes the previous browser child session',async()=>{
 mock.exchange.mockResolvedValue({error:null,data:{session:{},user:{id:'different-verified-adult'}}});
 const r=await GET(new Request('https://app.invalid/auth/callback?code=fixture',{headers:{cookie:headers.cookie+'; __Host-poortenboek-session='+ 'a'.repeat(43)}}));
 expect(mock.child).toHaveBeenCalledWith('poortenboek_child_action',{_token_hash:'hashed-previous-child-fixture',_action:'logout',_payload:{}});
 expect(r.cookies.get('__Host-poortenboek-session')?.maxAge).toBe(0);
 expect(r.cookies.get('__Host-poortenboek-demo')?.maxAge).toBe(0);
});
it('temporary child revocation failure still clears its cookie without undoing confirmed adult authentication',async()=>{
 mock.exchange.mockResolvedValue({error:null,data:{session:{},user:{id:'verified'}}});mock.child.mockRejectedValue(new Error('network'));
 const r=await GET(new Request('https://app.invalid/auth/callback?code=fixture',{headers:{cookie:headers.cookie+'; __Host-poortenboek-session='+ 'a'.repeat(43)}}));
 expect(r.headers.get('location')).toBe('https://app.invalid/omgeving/kiezen');expect(r.cookies.get('__Host-poortenboek-session')?.maxAge).toBe(0);
});
