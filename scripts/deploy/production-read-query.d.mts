type Environment = Record<string, string | undefined>;
type QueryResult = { command?: string; fields?: unknown[]; rows: Record<string, unknown>[] };
type Client = {
  on(event: string, listener: (error: unknown) => void): unknown;
  connect(): Promise<unknown>;
  query(query: { text: string; query_timeout: number }): Promise<QueryResult | QueryResult[]>;
  end(): Promise<unknown>;
};
export function enabledSessionReads(env?: Environment): boolean;
export function sessionReadQuery(sql: string, env?: Environment, request?: typeof fetch,
  ClientOverride?: new (configuration: Record<string, unknown>) => Client): Promise<Record<string, unknown>[]>;
