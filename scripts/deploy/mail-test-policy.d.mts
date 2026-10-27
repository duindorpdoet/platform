export function mailTestPolicy(context: Record<string, string | undefined>, now?: number): { skip: boolean; source: string; sha: string; reason: string };
