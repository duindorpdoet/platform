export const FRIGHTNIGHT_STAGING: Readonly<{origin:string;projectRef:string;slug:string}>;
export function assertFrightnightRelease(env: Record<string,string|undefined>): typeof FRIGHTNIGHT_STAGING;
export const FRIGHTNIGHT_SAFETY_SQL: string;
export type FrightnightSafety = {
 tables:number; unsafeTables:number; unsafeFunctions:number; actorFunctions:number; unsafeEvents:number; unsafeSink:number; sinkHasRecipient:boolean; legacyBindings:number;
 edition:null|{slug:string;date:string;timezone:string;phase:string;environment:string;isTest:boolean;retentionUntil:string};
 mailWorker:{active:boolean;endpoint:string;hasSecret:boolean}; legacyJobs:Array<{name:string;active:boolean;schedule:string}>;
};
export function assertFrightnightSafety(safety:FrightnightSafety,requireEdition?:boolean):FrightnightSafety;
