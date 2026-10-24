import {afterEach,describe,expect,it,vi} from 'vitest';
import {withRequestDeadline} from './request-deadline';
afterEach(()=>vi.useRealTimers());
describe('bounded requests under a connection that stays online',()=>{
 it('aborts a hanging transport after eight seconds',async()=>{
  vi.useFakeTimers();let signal:AbortSignal|undefined;
  const transport=Object.assign(new Promise<never>(()=>{}),{abortSignal:(value:AbortSignal)=>{signal=value;return new Promise<never>(()=>{});}});
  const waiting=expect(withRequestDeadline(transport)).rejects.toThrow('REQUEST_TIMEOUT');
  await vi.advanceTimersByTimeAsync(7999);expect(signal?.aborted).toBe(false);
  await vi.advanceTimersByTimeAsync(1);await waiting;expect(signal?.aborted).toBe(true);
 });
 it('does not abort a completed response later',async()=>{
  vi.useFakeTimers();let signal:AbortSignal|undefined;
  const transport=Object.assign(Promise.resolve({accepted:true}),{abortSignal:(value:AbortSignal)=>{signal=value;return Promise.resolve({accepted:true});}});
  expect(await withRequestDeadline(transport)).toEqual({accepted:true});await vi.advanceTimersByTimeAsync(16000);expect(signal?.aborted).toBe(false);
 });
});
