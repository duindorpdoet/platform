import {it,expect} from 'vitest';
import {guidanceRole,guidanceReturnPath,resumeGuidancePath} from './guidance-state';
import {guidanceRequest} from './guidance-request';
import {GuidanceRequests} from './guidance-requests';
import {guidanceProblem} from './guidance-errors';
it('starts only in a selected environment and repairs every legacy return entry',()=>{
 for(const path of ['/','/inloggen','/huis-aanmelden','/meelopen','/omgeving/kiezen','/app','/poortenboek'])expect(guidanceRole(path)).toBeNull();
 expect(guidanceRole('/mijn-huis')).toBe('house');expect(guidanceRole('/omgeving/meeloper/nu')).toBe('parent');
 for(const value of ['/',undefined,'','/omgeving/kiezen','/inloggen']){
  expect(guidanceReturnPath(value,'house')).toBe('/mijn-huis');expect(guidanceReturnPath(value,'parent')).toBe('/omgeving/meeloper/nu');
 }
 expect(guidanceReturnPath('/mijn-huis?poort=123&tab=Mijn%20team','house')).toBe('/mijn-huis?poort=123&tab=Mijn%20team');
 expect(guidanceReturnPath('/omgeving/meeloper/groep?filter=nu#groep','parent')).toBe('/omgeving/meeloper/groep?filter=nu#groep');
 expect(resumeGuidancePath('https://example.invalid','house')).toBe('/mijn-huis');
});
it.each(['https://example.invalid','//example.invalid','/\\example.invalid','/mijn-huis\\x','/%5cexample.invalid','/%252f%252fexample.invalid','/mijn-huis\n','/mijn-huis?x=%0d','/'+ 'a'.repeat(4096)])('rejects unsafe incoming tour destinations: %j',value=>{
 expect(()=>guidanceReturnPath(value,'house')).toThrow();
 expect(guidanceRequest.safeParse({action:'tutorial',role:'house',version:1,index:1,returnPath:value}).success).toBe(false);
});
it('normalizes the actual old-client root payload before the unchanged RPC contract',()=>{
 expect(guidanceRequest.parse({action:'tutorial',role:'house',version:1,index:1,returnPath:'/'})).toMatchObject({returnPath:'/mijn-huis'});
 expect(guidanceRequest.safeParse({action:'tutorial',role:'house',version:2,index:1,returnPath:'/mijn-huis'}).success).toBe(false);
});
it('invalidates reads across confirmed saves and writes across account/role changes',()=>{
 const requests=new GuidanceRequests(),old=requests.beginRead()!;
 const write=requests.beginWrite()!;expect(requests.beginWrite()).toBeNull();expect(requests.beginRead()).toBeNull();
 expect(requests.acceptsRead(old)).toBe(false);requests.endWrite(write);expect(requests.acceptsRead(old)).toBe(false);
 const fresh=requests.beginRead()!,newer=requests.beginRead()!;expect(requests.acceptsRead(fresh)).toBe(false);expect(requests.acceptsRead(newer)).toBe(true);
 const previousAccount=requests.beginWrite()!;requests.invalidate();const current=requests.beginWrite()!;
 expect(requests.acceptsWrite(previousAccount)).toBe(false);requests.endWrite(previousAccount);expect(requests.acceptsWrite(current)).toBe(true);
});
it('distinguishes recovery actions without exposing raw SQL or request fields',()=>{
 expect(new Set([guidanceProblem(),guidanceProblem(401),guidanceProblem(403),guidanceProblem(422),guidanceProblem(409),guidanceProblem(503)].map(p=>p.message)).size).toBe(6);
 expect(guidanceProblem(422,'INVALID_INPUT','safe-reference-1').requestId).toBe('safe-reference-1');
 expect(guidanceProblem(500,'RAW_SQL','unsafe\nvalue').requestId).toBeUndefined();
});
