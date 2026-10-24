import {afterEach,describe,expect,it,vi} from 'vitest';
import {createCoalescedRefresh} from './coalesced-refresh';
afterEach(()=>vi.useRealTimers());
describe('live snapshot invalidations',()=>{
 it('turns a hundred simultaneous notifications into one actual refresh',async()=>{
  vi.useFakeTimers();const refresh=vi.fn(),queue=createCoalescedRefresh(refresh);
  for(let n=0;n<100;n++)queue.request();
  await vi.advanceTimersByTimeAsync(250);
  expect(refresh).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(5000);expect(refresh).toHaveBeenCalledTimes(1);queue.dispose();
 });
 it('waits for the in-flight read and then reads changes that arrived meanwhile once',async()=>{
  vi.useFakeTimers();let complete!:()=>void;
  const refresh=vi.fn().mockImplementationOnce(()=>new Promise<void>(resolve=>{complete=resolve;})).mockResolvedValue(undefined),queue=createCoalescedRefresh(refresh);
  queue.request();await vi.advanceTimersByTimeAsync(250);
  for(let n=0;n<100;n++)queue.request();await vi.advanceTimersByTimeAsync(2000);
  expect(refresh).toHaveBeenCalledTimes(1);
  complete();await vi.advanceTimersByTimeAsync(1);expect(refresh).toHaveBeenCalledTimes(2);
  await vi.advanceTimersByTimeAsync(5000);expect(refresh).toHaveBeenCalledTimes(2);queue.dispose();
 });
 it('does not let a continuous notification stream postpone refresh forever',async()=>{
  vi.useFakeTimers();const refresh=vi.fn(),queue=createCoalescedRefresh(refresh);
  for(let n=0;n<20;n++){queue.request();await vi.advanceTimersByTimeAsync(100);}
  expect(refresh).toHaveBeenCalledTimes(2);queue.dispose();
 });
 it('cancels queued work on unmount and can recover after a failed source read',async()=>{
  vi.useFakeTimers();const refresh=vi.fn().mockRejectedValueOnce(new Error('source unavailable')).mockResolvedValue(undefined),queue=createCoalescedRefresh(refresh);
  queue.request();await vi.advanceTimersByTimeAsync(250);
  queue.request();await vi.advanceTimersByTimeAsync(250);expect(refresh).toHaveBeenCalledTimes(2);
  queue.request();queue.dispose();await vi.advanceTimersByTimeAsync(5000);expect(refresh).toHaveBeenCalledTimes(2);
 });
});
