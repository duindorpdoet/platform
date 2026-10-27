"use client";
// An aborted HTTP request can still have committed on the server. Callers must
// reconcile mutations using their original command/version rather than retrying blindly.
export async function withRequestDeadline<T extends PromiseLike<unknown>>(request:T,milliseconds=8000):Promise<Awaited<T>>{
 const controller=new AbortController(),abortable=request as T&{abortSignal?:(signal:AbortSignal)=>T};let timer:ReturnType<typeof setTimeout>|undefined;
 try{return await Promise.race([Promise.resolve(abortable.abortSignal?abortable.abortSignal(controller.signal):request),new Promise<never>((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(new Error('REQUEST_TIMEOUT'));},milliseconds);})]);}
 finally{if(timer)clearTimeout(timer);}
}
