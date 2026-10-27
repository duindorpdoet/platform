type Environment=Record<string,string|undefined>;
type Request=(url:string,init:RequestInit)=>Promise<Response>;
type Snapshot={revision:number;active_id:string};
export function activationPolicy(env:Environment,now?:number):boolean;
export function adminIds(value:string|undefined):string[];
export function inspectionQuery(env:Environment):string;
export function activationQuery(env:Environment,before:Snapshot):string;
export function verifyResendConfiguration(env:Environment,fromEmail:string,request?:Request):Promise<{domainVerified:boolean;trackingDisabled:boolean;ownSignedWebhookConfigured:boolean;deliveryValidated:boolean}>;
export function activateResendRelease(env?:Environment,request?:Request):Promise<void>;
