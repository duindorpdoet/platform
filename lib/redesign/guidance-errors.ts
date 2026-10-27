export type GuidanceProblem = {kind:'network'|'session'|'access'|'invalid'|'conflict'|'server';message:string;requestId?:string};
export function guidanceProblem(status?:number,code?:string,requestId?:string):GuidanceProblem {
  const reference=requestId&&/^[\w-]{1,100}$/.test(requestId)?requestId:undefined;
  const kind=!status?'network':status===401?'session':status===403?'access':status===409||code==='TUTORIAL_STEP_REQUIRED'?'conflict':status===400||status===422?'invalid':'server';
  const messages={network:'De verbinding is onderbroken. Je blijft bij deze stap. Probeer opnieuw zodra je verbinding hebt.',session:'Je sessie is verlopen. Log opnieuw in om deze uitleg te vervolgen.',access:'Je hebt nu geen toegang tot deze omgeving. Controleer je toegang of neem contact op met de organisatie.',invalid:'Deze uitleggegevens zijn verouderd of ongeldig. Laad de actuele uitleg opnieuw.',conflict:'De voortgang is intussen gewijzigd. Laad de actuele uitleg en ga daar verder.',server:'Bewaren lukt nu even niet. Je blijft bij deze stap. Probeer het straks opnieuw.'};
  return {kind,message:messages[kind],requestId:reference};
}
export class GuidanceRequestError extends Error {
  constructor(readonly problem:GuidanceProblem){super(problem.message);}
}
export async function readGuidanceResponse(response:Response) {
  const body=await response.json().catch(()=>null);
  if(!response.ok)throw new GuidanceRequestError(guidanceProblem(response.status,body?.error?.code,body?.error?.requestId));
  if(!body?.userId||!body?.eventId||!Array.isArray(body.roles))throw new GuidanceRequestError(guidanceProblem(500));
  return body as import('./guidance-state').GuidanceRecord;
}
