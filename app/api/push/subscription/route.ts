import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { readBoundedJson } from "@/lib/http/bounded-json";
import { getActor } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { validatePushEndpoint } from "@/lib/pwa/push-policy";
import { validPushKeys } from "@/lib/pwa/push-security";

export const runtime="nodejs";
export const dynamic="force-dynamic";
const subscriptionSchema=z.object({endpoint:z.string().max(4096),keys:z.object({p256dh:z.string().max(128),auth:z.string().max(64)}).strict(),deviceLabel:z.string().trim().max(120).optional()}).strict();
const preferenceSchema=z.object({enabled:z.boolean()}).strict();
const deleteSchema=z.object({id:z.uuid().optional(),endpoint:z.string().max(4096).optional()}).strict().refine(value=>value.id||value.endpoint);

async function authenticatedClient() {
  const actor=await getActor();const client=await createClient();
  if (!actor||!client) throw new ApiError(401,"NOT_AUTHORIZED","Log opnieuw in om meldingen te beheren.");
  return client;
}
type WriteError={error?:{code?:string};allowed?:boolean;permit?:string;code?:string};
function checkWriteError(data:WriteError|null) {
  const code=data?.error?.code??(data?.allowed===false?data.code:null);
  if (!code) return;
  if (code==="PUSH_RATE_LIMIT") throw new ApiError(429,code,"Even rustig aan. Probeer het over een minuut opnieuw.");
  if (code==="DEVICE_LIMIT_REACHED") throw new ApiError(409,code,"Er passen maximaal vijf apparaten bij één account. Verwijder eerst een oud apparaat.");
  throw new ApiError(400,code,"De apparaatinschrijving is niet opgeslagen. Schrijf dit apparaat opnieuw in.");
}
export async function GET(request:Request) {
  try {
    const client=await authenticatedClient();
    const {data,error}=await client.schema("api").rpc("push_subscription_state");
    if (error) throw error;
    return apiSuccess(data);
  } catch(error) {return apiFailure(error,correlationId(request));}
}
async function write(request:Request,operation:"POST"|"PATCH"|"DELETE") {
  try {
    assertTrustedOrigin(request);
    const client=await authenticatedClient();
    // Its own transaction: even malformed JSON and rejected keys consume a write.
    const attempt=await client.schema("api").rpc("push_write_attempt");
    if (attempt.error) throw attempt.error;
    checkWriteError(attempt.data);
    const raw=await readBoundedJson(request);
    let payload;
    if (operation==="POST") {
      const input=subscriptionSchema.parse(raw);const endpoint=validatePushEndpoint(input.endpoint);
      if (!endpoint||!validPushKeys(input.keys.p256dh,input.keys.auth)) throw new ApiError(400,"INVALID_SUBSCRIPTION","De pushbestemming of encryptiesleutels zijn ongeldig. Schrijf het apparaat opnieuw in.");
      payload={...input,endpoint};
    } else payload=operation==="PATCH"?preferenceSchema.parse(raw):deleteSchema.parse(raw);
    const {data,error}=await client.schema("api").rpc("push_subscription_write",{
      _permit:attempt.data.permit,_operation:operation,_payload:payload,_user_agent:request.headers.get("user-agent")?.slice(0,500)??null,
    });
    if (error) throw error;
    checkWriteError(data);
    return apiSuccess(data,operation==="POST"?201:200);
  } catch(error) {return apiFailure(error,correlationId(request));}
}
export const POST=(request:Request)=>write(request,"POST");
export const PATCH=(request:Request)=>write(request,"PATCH");
export const DELETE=(request:Request)=>write(request,"DELETE");
