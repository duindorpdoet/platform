export type JointRoutePolicyReleaseSnapshot={capturedAt:string;migrationApplied:boolean;appliedMigrations?:string[];tableExists:boolean;rows:Array<{policy_version:string;activated_at:string}>};
export function jointRoutePolicyReleaseQuery(catalog:Array<{schema:string;name:string}>):string;
export const JOINT_ROUTE_POLICY_MIGRATION:string;
export const JOINT_ROUTE_POLICY_V3_MIGRATION:string;
export function reconcileJointRoutePolicyRelease(before:JointRoutePolicyReleaseSnapshot,after:JointRoutePolicyReleaseSnapshot,expectedVersions:string[]):{failures:string[];reconciledTables:string[];addedPolicyReleases:number};
