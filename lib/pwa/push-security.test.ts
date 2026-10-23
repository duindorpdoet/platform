import { afterEach,beforeEach,describe,expect,it,vi } from "vitest";
import { createECDH,randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import webPush from "web-push";
vi.mock("server-only",()=>({}));
const mocks=vi.hoisted(()=>({lookup:vi.fn(),request:vi.fn(),rpc:vi.fn(),env:{} as Record<string,string>}));
vi.mock("node:dns/promises",()=>({lookup:mocks.lookup}));
vi.mock("node:https",()=>({request:mocks.request}));
vi.mock("@/lib/config/server-env",()=>({serverEnv:()=>mocks.env}));
vi.mock("@/lib/supabase/privileged",()=>({createPrivilegedClient:()=>({schema:()=>({rpc:(...args:unknown[])=>({abortSignal:(signal:AbortSignal)=>mocks.rpc(...args,signal)})})})}));
import { validatePushEndpoint } from "./push-policy";
import { createPushBatchBudget,isPublicPushAddress,runBoundedPushBatch,sendSecurePush,validPushKeys,type SafePushTarget } from "./push-security";
import { deliverScopedPush } from "./push-delivery";

const key=createECDH("prime256v1");key.generateKeys();
const target:SafePushTarget={subscriptionId:"fixture-device",fingerprint:"fixture-hash",endpoint:"https://fcm.googleapis.com/fcm/send/isolated-fixture",p256dh:key.getPublicKey().toString("base64url"),auth:randomBytes(16).toString("base64url")};
beforeEach(()=>{
  vi.clearAllMocks();const vapid=webPush.generateVAPIDKeys();
  Object.assign(mocks.env,{VAPID_SUBJECT:"mailto:isolated@example.invalid",NEXT_PUBLIC_VAPID_PUBLIC_KEY:vapid.publicKey,VAPID_PRIVATE_KEY:vapid.privateKey});
  mocks.lookup.mockResolvedValue([{address:"142.250.74.202",family:4}]);
});
afterEach(()=>vi.useRealTimers());

describe("SEC-01 admission and sender validation",()=>{
  it.each(["fcm.googleapis.com","updates.push.services.mozilla.com","web.push.apple.com"])("allows only the exact HTTPS provider %s",host=>{
    expect(validatePushEndpoint(`https://${host}/fixture`)).toBe(`https://${host}/fixture`);
    expect(validatePushEndpoint(`https://${host}:443/fixture`)).toBe(`https://${host}/fixture`);
  });
  it.each(["http://fcm.googleapis.com/fcm/send/token","https://127.0.0.1/a","https://[::1]/a","https://localhost/a",
    "https://fcm.googleapis.com.evil.invalid/a","https://fcm.googleapis.com@evil.invalid/a","https://user:secret@fcm.googleapis.com/a",
    "https://fcm.googleapis.com:444/a","https://fcm.googleapis.com/a?secret=x","https://fcm.googleapis.com/a#x",
    "https://fcm.googleapis.com/","https://fcm.googleapis.com/a\\b"," https://fcm.googleapis.com/a",
    "https://fcm.googleapis.com/a\n","https://fcm.googleapis.com/%5cinternal","https://fcm.googleapis.com/"+"x".repeat(4096)])("rejects an unsafe endpoint without transport: %s",endpoint=>{
    expect(validatePushEndpoint(endpoint)).toBeNull();
  });
  it("validates the actual P-256 point, not only its length",()=>{
    expect(validPushKeys(target.p256dh,target.auth)).toBe(true);
    expect(validPushKeys(Buffer.concat([Buffer.from([4]),Buffer.alloc(64)]).toString("base64url"),target.auth)).toBe(false);
    expect(validPushKeys(target.p256dh,Buffer.alloc(15).toString("base64url"))).toBe(false);
  });
  it.each(["0.0.0.0","10.1.2.3","100.64.1.1","127.0.0.1","169.254.169.254","172.16.1.1","192.168.1.1","192.0.2.1","198.18.1.1","224.0.0.1","255.255.255.255","::1","::ffff:127.0.0.1","fc00::1","fe80::1","2001:db8::1","2002:7f00:1::1"])("blocks non-public DNS answer %s",address=>expect(isPublicPushAddress(address)).toBe(false));
  it.each(["142.250.74.202","17.188.171.82","2607:f8b0:4007:80a::200a"])("permits a public provider address %s",address=>expect(isPublicPushAddress(address)).toBe(true));
  it("never invokes HTTPS for an unsafe legacy record",async()=>{
    expect(await sendSecurePush({...target,endpoint:"https://169.254.169.254/secret"},"neutral",new AbortController().signal)).toMatchObject({deactivate:true,error:"UNSAFE_SUBSCRIPTION"});
    expect(mocks.request).not.toHaveBeenCalled();expect(mocks.lookup).not.toHaveBeenCalled();
  });
  it("uses the validated DNS result for the actual connection and rejects a mixed private answer",async()=>{
    let options:Record<string,unknown>={};
    mocks.request.mockImplementation((value,callback)=>{
      options=value;const req=new EventEmitter() as EventEmitter&{end:()=>void};req.end=()=>{
        const response=new EventEmitter() as EventEmitter&{statusCode:number};response.statusCode=201;callback(response);queueMicrotask(()=>response.emit("end"));
      };return req;
    });
    expect((await sendSecurePush(target,"neutral",new AbortController().signal)).success).toBe(true);
    expect(options).toMatchObject({hostname:"fcm.googleapis.com",port:443,agent:false,rejectUnauthorized:true});
    mocks.lookup.mockResolvedValue([{address:"142.250.74.202",family:4},{address:"10.0.0.1",family:4}]);
    const callback=vi.fn();
    (options.lookup as (host:string,options:unknown,callback:unknown)=>void)("fcm.googleapis.com",{all:true},callback);
    await vi.waitFor(()=>expect(callback).toHaveBeenCalled());
    expect(callback.mock.calls[0][0]).toBeInstanceOf(Error);
    expect(callback.mock.calls[0][1]).toBe("");
  });
  it("does not follow a provider redirect and never retains its response body",async()=>{
    mocks.request.mockImplementation((_options,callback)=>{
      const req=new EventEmitter() as EventEmitter&{end:()=>void};req.end=()=>{
        const response=new EventEmitter() as EventEmitter&{statusCode:number};response.statusCode=302;callback(response);queueMicrotask(()=>response.emit("end"));
      };return req;
    });
    expect(await sendSecurePush(target,"neutral",new AbortController().signal)).toMatchObject({success:false,error:"PUSH_REDIRECT_BLOCKED"});
    expect(mocks.request).toHaveBeenCalledTimes(1);
  });
});

describe("SEC-01 shared worker budget and current-account recheck",()=>{
  it("shares twenty attempts across channels with at most three concurrent sends",async()=>{
    let active=0,max=0,total=0;
    const deliver=async()=>{active++;max=Math.max(max,active);total++;await new Promise(r=>setTimeout(r,2));active--;return {success:true,deactivate:false,error:null};};
    const budget=createPushBatchBudget();
    const first=await runBoundedPushBatch(Array.from({length:15},(_,i)=>i),deliver,budget);
    const second=await runBoundedPushBatch(Array.from({length:15},(_,i)=>i+15),deliver,budget);
    expect(first.size+second.size).toBe(20);expect(total).toBe(20);expect(max).toBe(3);
  });
  it("stops a non-cooperating sender at two seconds per attempt and eight seconds per batch",async()=>{
    vi.useFakeTimers();const signals:AbortSignal[]=[];
    const work=runBoundedPushBatch(Array.from({length:20},(_,i)=>i),async(_item,signal)=>{signals.push(signal);return new Promise(()=>{});});
    await vi.advanceTimersByTimeAsync(8_001);const results=await work;
    expect(results.size).toBe(12);expect(signals).toHaveLength(12);expect(signals.every(signal=>signal.aborted)).toBe(true);
    expect([...results.values()].every(result=>result.error==="ACCEPTANCE_UNCERTAIN")).toBe(true);
    await vi.advanceTimersByTimeAsync(60_000);expect(signals).toHaveLength(12);
  });
  it("does not send a target whose current ownership, key fingerprint or preference changed",async()=>{
    mocks.rpc.mockResolvedValue({data:null,error:null});
    expect(await deliverScopedPush(target,{notificationId:"notice",claimToken:"lease"},"neutral",new AbortController().signal)).toMatchObject({success:false,deferred:true});
    expect(mocks.rpc).toHaveBeenCalledWith("worker_push_target",expect.objectContaining({_subscription:target.subscriptionId,_fingerprint:target.fingerprint,_notification:"notice",_token:"lease",_test_user_id:null}),expect.any(AbortSignal));
    expect(mocks.request).not.toHaveBeenCalled();
  });
  it("quarantines invalid legacy subscriptions before any provider request",async()=>{
    mocks.rpc.mockResolvedValue({data:{blocked:true},error:null});
    expect(await deliverScopedPush(target,{notificationId:"notice",claimToken:"lease"},"neutral",new AbortController().signal)).toMatchObject({deactivate:true,error:"UNSAFE_SUBSCRIPTION"});
    expect(mocks.request).not.toHaveBeenCalled();
  });
});
