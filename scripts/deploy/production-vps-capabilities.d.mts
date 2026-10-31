type Environment = Record<string, string | undefined>;
type Execution = (name: string, args: string[], timeoutMs: number) => Promise<{available: boolean;stdout: string}>;
export function runVpsCapabilities(env?: Environment, execute?: Execution,
  filesystem?: (path: string) => Promise<{bavail: bigint;bsize: bigint}>): Promise<{
    diagnostic: string;scope: string;databaseAccessed: boolean;sqlSent: boolean;
    tools: Record<string,{available: boolean;version: string|null}>;workspaceAvailableBytes: number|null;tempAvailableBytes: number|null;dockerServerReachable: boolean;
  }>;
