import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {findAddress} from '/home/codex/repos/duindorphalloween-frightnight-2027/lib/frightnight/geocoding.ts';
import {walkingRoute} from '/home/codex/repos/duindorphalloween-frightnight-2027/lib/frightnight/walking.ts';
const root='/home/codex/repos/duindorphalloween-frightnight-2027',output='/tmp/frightnight-provider-adapter-probe/report.json';
const hash=x=>createHash('sha256').update(x).digest('hex');
const sources=['lib/frightnight/geocoding.ts','lib/frightnight/walking.ts'];
const report={scope:'One actual bounded read-only external adapter batch; public street query and public street coordinates only; no actor/DB/key/provider account',startedAt:new Date().toISOString(),revision:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),nodeVersion:process.version,sourceSha256:Object.fromEntries(await Promise.all(sources.map(async p=>[p,hash(await readFile(root+'/'+p))]))),requests:[],maxExternalRequests:2,providerAccounts:0,authRequests:0,databaseRequests:0,limits:['No authenticated/staging endpoint or database action was used.','A zero bounded-region address result is not a verified Duinpad address or pin.','Pedestrian provider geometry is not physical street safety, accessibility or organisation approval.','In-process immediate cache/coalescing does not prove24-hour TTL or VPS multi-process behavior.','No network fault was injected; fallback cannot be claimed unless an actual adapter error occurred.']};
let calls=0;
const native=globalThis.fetch;
async function transport(input,options={}){
 const url=new URL(String(input));
 assert.equal(url.protocol,'https:');assert(['api.pdok.nl','routing.openstreetmap.de'].includes(url.hostname));assert.equal(url.port,'');assert(!url.username&&!url.password);assert(!options.method||options.method==='GET');assert.equal(options.redirect,'error');assert.equal(options.cache,'no-store');assert(options.signal instanceof AbortSignal);assert(++calls<=2,'EXTERNAL_CALL_BOUND');
 assert(url.hostname==='api.pdok.nl'?url.pathname==='/bzk/locatieserver/search/v3_1/free':url.pathname.startsWith('/routed-foot/route/v1/foot/'));
 const entry={number:calls,provider:url.hostname,url:url.href,method:'GET',redirect:'error',cache:'no-store',startedAt:new Date().toISOString()};report.requests.push(entry);const start=performance.now();
 try{
  const response=await native(input,options);entry.status=response.status;entry.responseType=response.headers.get('content-type');
  const bytes=Buffer.from(await response.clone().arrayBuffer());assert(bytes.length<2*1024*1024,'PUBLIC_RESPONSE_SIZE_BOUND');entry.bytes=bytes.length;entry.responseSha256=hash(bytes);let data;try{data=JSON.parse(bytes)}catch{}
  if(url.hostname==='api.pdok.nl')entry.schemaObserved={responseDocsArray:Array.isArray(data?.response?.docs),docsCount:data?.response?.docs?.length??null,requiredDocStrings:data?.response?.docs?.every(x=>typeof x.id==='string'&&typeof x.weergavenaam==='string'&&typeof x.centroide_ll==='string')??false};
  else entry.schemaObserved={code:data?.code??null,routeCount:data?.routes?.length??null,geometryType:data?.routes?.[0]?.geometry?.type??null,points:data?.routes?.[0]?.geometry?.coordinates?.length??null,distanceMetres:data?.routes?.[0]?.distance??null,durationSeconds:data?.routes?.[0]?.duration??null};
  return response;
 }catch(error){entry.error={name:error?.name??'Error',code:error?.code??null};throw error}finally{entry.durationMs=Math.round(performance.now()-start)}
}
try{
 const startCalls=calls;
 try{const candidates=await findAddress('Duinpad',transport);assert(Array.isArray(candidates));assert(candidates.every(x=>x.latitude>=52.075&&x.latitude<=52.115&&x.longitude>=4.22&&x.longitude<=4.29));const again=await findAddress('Duinpad',transport);assert.deepEqual(again,candidates);assert.equal(calls,startCalls+1);report.pdok={adapterResult:'schema_validated',query:'Duinpad (public street) Den Haag',candidatesWithinConfiguredRegion:candidates.length,immediateIdenticalQueryCacheHit:true,extraCacheNetworkRequests:0,verifiedStreetPin:candidates.length>0};}
 catch(error){report.pdok={adapterResult:'error',errorName:error?.name??'Error',errorCode:error?.code??null,fallbackInterpretation:'The authenticated route catches provider failure into empty candidates and explicit no-pin message; that route/UI was not invoked in this probe.'};}
 const from={latitude:52.0934,longitude:4.2521},to={latitude:52.0935,longitude:4.2557},beforeWalk=calls;
 try{const[first,coalesced]=await Promise.all([walkingRoute(from,to,transport),walkingRoute(from,to,transport)]);assert.deepEqual(first,coalesced);assert.equal(first.available,true);assert.equal(first.geometry.type,'LineString');assert(first.geometry.coordinates.length>=2&&first.geometry.coordinates.length<=5000);assert(Number.isInteger(first.minutes)&&first.minutes>=1);const again=await walkingRoute(from,to,transport);assert.deepEqual(again,first);assert.equal(calls,beforeWalk+1);report.walking={adapterResult:'schema_validated',from,to,available:first.available,source:first.source,minutes:first.minutes,geometryType:first.geometry.type,points:first.geometry.coordinates.length,geometrySha256:hash(JSON.stringify(first.geometry)),coordinates:first.geometry.coordinates,inflightIdenticalCallsCoalesced:true,immediateIdenticalRouteCacheHit:true,extraCoalesceAndCacheNetworkRequests:0};}
 catch(error){report.walking={adapterResult:'error',errorName:error?.name??'Error',errorCode:error?.code??null,fallbackInterpretation:'The authenticated route catches provider failure into availablefalse/no invented line; that route/UI was not invoked in this probe.'};}
 for(const path of sources)assert.equal(hash(await readFile(root+'/'+path)),report.sourceSha256[path]);
 report.sourceUnchanged=true;report.externalCalls=calls;report.status=report.pdok.adapterResult==='schema_validated'&&report.walking.adapterResult==='schema_validated'?'passed_actual_external_adapter_contract':'partial_or_environment_provider_unavailable';
}finally{report.completedAt=new Date().toISOString();await writeFile(output,JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify({output,status:report.status,pdok:report.pdok,walking:report.walking?{...report.walking,coordinates:undefined}:null,externalCalls:calls,reportSha256:hash(await readFile(output))}));}
