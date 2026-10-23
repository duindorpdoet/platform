import "server-only";
import { ECDH } from "node:crypto";
import { lookup } from "node:dns/promises";
import { request } from "node:https";
import { BlockList, isIP } from "node:net";
import webPush from "web-push";
import { serverEnv } from "@/lib/config/server-env";
import { PUSH_PROVIDER_HOSTS, PUSH_SECURITY_POLICY, validPushKeyShape, validatePushEndpoint } from "./push-policy";

export type SafePushTarget = { subscriptionId: string; endpoint: string; p256dh: string; auth: string; fingerprint: string };
export type PushResult = { success: boolean; deactivate: boolean; error: string | null; deferred?: boolean };

export function validPushKeys(p256dh: unknown, auth: unknown) {
  if (!validPushKeyShape(p256dh, 65) || !validPushKeyShape(auth, 16)) return false;
  try {
    return ECDH.convertKey(Buffer.from(p256dh as string, "base64url"), "prime256v1", undefined, undefined, "uncompressed").length === 65;
  } catch { return false; }
}

const privateV4 = new BlockList();
for (const [base, prefix] of [["0.0.0.0",8],["10.0.0.0",8],["100.64.0.0",10],["127.0.0.0",8],["169.254.0.0",16],
  ["172.16.0.0",12],["192.0.0.0",24],["192.0.2.0",24],["192.88.99.0",24],["192.168.0.0",16],
  ["198.18.0.0",15],["198.51.100.0",24],["203.0.113.0",24],["224.0.0.0",4],["240.0.0.0",4]] as const) privateV4.addSubnet(base,prefix,"ipv4");
const globalV6 = new BlockList(); globalV6.addSubnet("2000::",3,"ipv6");
const reservedV6 = new BlockList();
for (const [base,prefix] of [["2001::",23],["2001:db8::",32],["2002::",16],["3fff::",20]] as const) reservedV6.addSubnet(base,prefix,"ipv6");
export function isPublicPushAddress(address: string) {
  return isIP(address) === 4 ? !privateV4.check(address,"ipv4")
    : isIP(address) === 6 && globalV6.check(address,"ipv6") && !reservedV6.check(address,"ipv6");
}

/** web-push performs VAPID/encryption; Node HTTPS owns DNS, abort and redirects.
 * Unlike the library's socket timeout, this signal also covers DNS and a slow body. */
export async function sendSecurePush(target: SafePushTarget, payload: string, signal: AbortSignal, ttl = 300): Promise<PushResult> {
  signal=AbortSignal.any([signal,AbortSignal.timeout(PUSH_SECURITY_POLICY.attemptTimeoutMs)]);
  const endpoint = validatePushEndpoint(target.endpoint);
  if (!endpoint || !validPushKeys(target.p256dh,target.auth)) return {success:false,deactivate:true,error:"UNSAFE_SUBSCRIPTION"};
  if (signal.aborted) return {success:false,deactivate:false,error:"PUSH_DEADLINE",deferred:true};
  const env=serverEnv();
  if (!env.VAPID_SUBJECT || !env.NEXT_PUBLIC_VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY) return {success:false,deactivate:false,error:"NOT_CONFIGURED"};
  try {
    const details=webPush.generateRequestDetails({endpoint,keys:{p256dh:target.p256dh,auth:target.auth}},payload,{
      TTL:ttl,vapidDetails:{subject:env.VAPID_SUBJECT,publicKey:env.NEXT_PUBLIC_VAPID_PUBLIC_KEY,privateKey:env.VAPID_PRIVATE_KEY},
    });
    const url=new URL(endpoint);
    const status=await new Promise<number>((resolve,reject)=>{
      const req=request({hostname:url.hostname,port:443,path:url.pathname,method:"POST",headers:details.headers,
        agent:false,signal,rejectUnauthorized:true,maxHeaderSize:16_384,
        lookup:(hostname,options,callback)=>{
          if (!PUSH_PROVIDER_HOSTS.includes(hostname)) { callback(new Error("PUSH_DNS_BLOCKED"),"",4); return; }
          void lookup(hostname,{all:true,verbatim:true}).then(addresses=>{
            if (signal.aborted || !addresses.length || addresses.some(a=>!isPublicPushAddress(a.address))) throw new Error("PUSH_DNS_BLOCKED");
            if (options.all) callback(null,addresses);
            else callback(null,addresses[0].address,addresses[0].family);
          }).catch(()=>callback(new Error("PUSH_DNS_BLOCKED"),"",4));
        },
      },response=>{
        const code=response.statusCode??0;
        // No redirects. Response text, provider headers and tokens never enter logs.
        let bytes=0;
        response.on("data",(chunk:Buffer)=>{ bytes+=chunk.length; if (bytes>16_384) req.destroy(new Error("PUSH_RESPONSE_LIMIT")); });
        response.on("error",reject);
        response.on("end",()=>resolve(code));
      });
      req.on("error",reject);
      req.end(details.body);
    });
    return {success:status>=200&&status<300,deactivate:status===404||status===410,
      error:status>=200&&status<300?null:status>=300&&status<400?"PUSH_REDIRECT_BLOCKED":`HTTP_${status}`};
  } catch { return {success:false,deactivate:false,error:signal.aborted?"ACCEPTANCE_UNCERTAIN":"DELIVERY_FAILED"}; }
}

export type PushBatchBudget = { remaining: number; deadline: number };
export function createPushBatchBudget(): PushBatchBudget {
  return {remaining:PUSH_SECURITY_POLICY.maxBatchTargets,deadline:Date.now()+PUSH_SECURITY_POLICY.batchTimeoutMs};
}

/** The same budget is shared by both real worker channels in one scheduler tick. */
export async function runBoundedPushBatch<T>(items:T[],deliver:(item:T,signal:AbortSignal)=>Promise<PushResult>,budget=createPushBatchBudget()) {
  const results=new Map<T,PushResult>();
  const selected=items.slice(0,Math.max(0,budget.remaining));
  budget.remaining-=selected.length;
  let cursor=0;
  async function worker() {
    while(cursor<selected.length && Date.now()<budget.deadline) {
      const item=selected[cursor++];
      const controller=new AbortController();
      let timer:ReturnType<typeof setTimeout>|undefined;
      const timeout=new Promise<PushResult>(resolve=>{
        timer=setTimeout(()=>{controller.abort();resolve({success:false,deactivate:false,error:"ACCEPTANCE_UNCERTAIN"});},
          Math.max(1,Math.min(PUSH_SECURITY_POLICY.attemptTimeoutMs,budget.deadline-Date.now())));
      });
      try {
        const result=await Promise.race([deliver(item,controller.signal),timeout]);
        results.set(item,result);
      } catch { results.set(item,{success:false,deactivate:false,error:"DELIVERY_FAILED"}); }
      finally {clearTimeout(timer);controller.abort();}
    }
  }
  await Promise.all(Array.from({length:Math.min(PUSH_SECURITY_POLICY.concurrency,selected.length)},worker));
  return results;
}
