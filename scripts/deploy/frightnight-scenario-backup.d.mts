export type ScenarioSnapshot={slug:string;date:string;timezone:string;environment:string;isTest:boolean;seedVersion:number;closed:boolean;bindingDigest:string;unsafeSink:number;tables:Array<{table:string;rows:number;sha256:string}>};
export function scenarioBackupEnabled(env:Record<string,string|undefined>):boolean;
export function scenarioBackupQuery(catalog:Array<{schema:string;name:string;columns:string[]}>):string;
export function assertScenarioSnapshot(value:ScenarioSnapshot):ScenarioSnapshot;
export function compareScenarioRestore(before:ScenarioSnapshot,after:ScenarioSnapshot):{slug:string;seedVersion:number;tables:number;registrations:number;zones:number;sha256:string;restoreVerified:boolean};
