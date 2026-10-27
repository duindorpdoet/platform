export const LEGACY_HOTFIX:string;
export const CANONICAL_HOTFIX:string;
export const hotfixProofQuery:string;
type Proof={save_hash:string;cleanup_hash:string;trigger_valid:boolean;contaminated_drafts:number;versions:string[]};
export function assertEquivalentHotfix(staging:Proof,production:Proof):void;
