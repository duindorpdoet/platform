export type TogetherFixture = {
  partyId: string;
  clusterReference: string | null;
  members: Array<{ id: string; reference: string; togetherCode: string }>;
};
export function requireLocalTogetherDatabase(): string;
export function sql(query: string): string;
export function parallelSql(query: string): Promise<string>;
export function createTogetherFixtures(count?: number, members?: number, children?: number): TogetherFixture[];
