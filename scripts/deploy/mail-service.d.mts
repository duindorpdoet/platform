export function mailRpc(name:string,args:Record<string,unknown>):Promise<unknown>;
export function activeMailConfig():Promise<{provider:'resend'|'sendgrid';[key:string]:unknown}>;
