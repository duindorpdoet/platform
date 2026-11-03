export type SystemCronFile={directory:string;name:string;status:string;sha256?:string;scope:string};
export function timerScope(source:string):string;
export function summarizeSystemCronFile(directory:string,name:string,bytes:Buffer):SystemCronFile;
export function inventorySystemCron():Promise<{files:SystemCronFile[];directories:Array<{directory:string;status:string}>;boundaries:string[]}>;
export function unreviewedSystemCron(files:SystemCronFile[],reviewed:Set<string>):SystemCronFile[];
