export const AUDIT_QUERY: string;
export const PREVIEW_AUDIT_QUERY: string;
export const JOINT_PROPOSAL_INPUT_QUERY: string;
export const SNAPSHOT_STATS_QUERY: string;
export function ownerPreviewAllowed(env: Record<string, string | undefined>): boolean;
export function runAudit(env?: Record<string, string | undefined>, request?: (url: string, options: RequestInit) => Promise<Response>): Promise<string>;
