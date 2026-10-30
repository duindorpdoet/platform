import type { JointRouteSettingsInitializationSnapshot } from './joint-route-settings-reconciliation.mjs';
export const P12_ROUTE_POLICY_MIGRATION:string;
export type P12RoutePolicySnapshot={capturedAt:string;appliedMigrations:string[];tablesExist:boolean;
  settings:Array<Record<string,unknown>&{event_id:string}>;portals:Array<Record<string,unknown>&{id:string}>;
  windows:Array<Record<string,unknown>&{id:string}>;targetEvents:Array<{event_id:string;close_at:string}>};
export function p12RoutePolicyQuery(catalog:Array<{schema:string;name:string}>):string;
export function reconcileP12RoutePolicy(before:P12RoutePolicySnapshot|undefined,after:P12RoutePolicySnapshot|undefined,expectedVersions:string[]):{
  failures:string[];reconciledTables:string[];changedSettingsRows:number;changedPortalRows:number;changedWindowRows:number;
};
export function jointRouteSettingsBeforeP12Policy(before:P12RoutePolicySnapshot|undefined,after:P12RoutePolicySnapshot|undefined,expectedVersions:string[],settingsAfter:JointRouteSettingsInitializationSnapshot|undefined):JointRouteSettingsInitializationSnapshot|undefined;
