export const JOINT_ROUTE_SETTINGS_MIGRATION:string;
export type JointRouteSettingsInitializationSnapshot={
  capturedAt:string;migrationApplied:boolean;tableExists:boolean;
  rows:Array<Record<string,unknown>&{event_id:string}>;
  expectedTargets:Array<{event_id:string;organizer_coverage_portal_ids:string[]}>;
};
export function jointRouteSettingsInitializationQuery(catalog:Array<{schema:string;name:string}>):string;
export function reconcileJointRouteSettingsInitialization(before:JointRouteSettingsInitializationSnapshot|undefined,after:JointRouteSettingsInitializationSnapshot|undefined,expectedVersions:string[]):{
  failures:string[];reconciledTables:string[];initializedSettingsRows:number;
};
