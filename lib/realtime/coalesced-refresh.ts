// Broadcasts invalidate snapshots; one burst needs one read, with one trailing
// read if something changed while the previous request was still in flight.
export function createCoalescedRefresh(refresh:()=>void|Promise<unknown>,delayMs=250,maxWaitMs=1000){
 let timer:ReturnType<typeof setTimeout>|undefined,firstQueuedAt:number|null=null;
 let queued=false,running=false,disposed=false;
 const request=()=>{
  if(disposed)return;
  queued=true;firstQueuedAt??=performance.now();
  if(running)return;
  if(timer!==undefined)clearTimeout(timer);
  timer=setTimeout(()=>void run(),Math.min(delayMs,Math.max(0,maxWaitMs-(performance.now()-firstQueuedAt))));
 };
 const run=async()=>{
  timer=undefined;
  if(disposed||running||!queued)return;
  queued=false;firstQueuedAt=null;running=true;
  try{await refresh();}catch{/* The source retains its own error and freshness. */}
  finally{running=false;if(queued&&!disposed)request();}
 };
 return {request,dispose(){disposed=true;queued=false;if(timer!==undefined)clearTimeout(timer);}};
}
