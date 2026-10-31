type Environment = Record<string, string | undefined>;
export type AdminDatabasePlan = {
  host: string; port: 5432; database: "postgres"; user: string; password: string;
  ssl: {rejectUnauthorized: true; ca: string[]}; connectionTimeoutMillis: 30000; application_name: "duindorp-release-readonly";
};
type QueryResult = { command?: string; fields?: unknown[]; rows: Record<string, unknown>[] };
type Client = {
  on(event: string, listener: (error: unknown) => void): unknown;
  connect(): Promise<unknown>;
  query(query: { text: string; query_timeout: number }): Promise<QueryResult | QueryResult[]>;
  end(): Promise<unknown>;
};
export function enabledSessionReads(env?: Environment): boolean;
export function adminDatabasePlan(env: Environment, project: unknown, poolers?: unknown): AdminDatabasePlan;
export function publicReleaseCaBundle(): string;
export function sessionReadQuery(sql: string, env?: Environment, request?: typeof fetch,
  ClientOverride?: new (configuration: Record<string, unknown>) => Client): Promise<Record<string, unknown>[]>;
