import {describe,it,expect} from 'vitest';
import {REMEMBER_SECONDS,sessionCookieOptions} from './session-lifetime';
import {safeReturnPath} from './redirect';
describe('supported cookie lifetime and safe account return',()=>{
 it('uses persistent or browser-session auth cookies without inventing a token',()=>{
  expect(sessionCookieOptions('sb-project-auth-token.0',{secure:true,maxAge:31536000},true)).toMatchObject({secure:true,maxAge:REMEMBER_SECONDS,sameSite:'lax',path:'/'});
  expect(sessionCookieOptions('sb-project-auth-token',{maxAge:31536000,expires:new Date()},false)).toMatchObject({maxAge:undefined,expires:undefined});
 });
 it('preserves deletion and unrelated cookie policies',()=>{
  expect(sessionCookieOptions('sb-project-auth-token',{maxAge:0},true).maxAge).toBe(0);
  expect(sessionCookieOptions('child',{maxAge:43200},false).maxAge).toBe(43200);
 });
 it.each(['https://evil.invalid','//evil.invalid','/\\evil.invalid'])('rejects external returns %s',value=>expect(safeReturnPath(value,'/omgeving/kiezen')).toBe('/omgeving/kiezen'));
 it('keeps a valid internal destination',()=>expect(safeReturnPath('/mijn-huis?poort=123')).toBe('/mijn-huis?poort=123'));
});
