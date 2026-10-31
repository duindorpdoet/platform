import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import { preservationManagementRequest } from './redesign-backup.mjs';
import { readReleaseState } from './redesign-preflight.mjs';
import { releaseMetadataQuery } from './redesign-reconciliation.mjs';

const catalog = [{ schema: 'app_private', name: 'events', columns: ['id'] }];
const baseline = {
  migrationHistory: [], cronHistory: [], cronJobs: [], cronBoundary: '41',
  cronTerminal: { rows: 40, sha256: 'original-completed-runs' },
  mailEventIds: [], mailEventOriginal: { rows: 0, sha256: 'original-mail-events' },
  addedMailEvents: 0, invalidAddedMailEvents: 0,
  worldPolicyInitialization: { auditBoundary: '73' },
};

describe.each([
  { stage: 'preflight', before: undefined },
  { stage: 'postmigration', before: baseline },
])('$stage release reads', ({ before }) => {
  it('waits for metadata before starting domain preservation and retains both results', async () => {
    let resolveMetadata!: (value: unknown) => void;
    const pendingMetadata = new Promise(resolve => { resolveMetadata = resolve; });
    const metadata = [{ metadata: { cronBoundary: '42', originalEvents: 'unchanged' } }];
    const preservation = [{ preservation: { rows: ['unchanged-domain-fingerprints'] } }];
    const request = vi.fn().mockReturnValueOnce(pendingMetadata).mockResolvedValueOnce(preservation);

    const pending = readReleaseState(catalog, before, request);
    expect(request).toHaveBeenCalledTimes(1);
    expect(request).toHaveBeenNthCalledWith(1, '/database/query', {
      read_only: true, query: releaseMetadataQuery(before),
    });
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    resolveMetadata(metadata);
    await expect(pending).resolves.toEqual({ metadata, preservation });
    expect(request).toHaveBeenCalledTimes(2);
    expect(request).toHaveBeenNthCalledWith(2, '/database/query',
      preservationManagementRequest(catalog, before?.worldPolicyInitialization));
  });

  it('never starts expensive preservation when metadata fails', async () => {
    const error = new Error('RELEASE_READ_SQLSTATE_57014');
    const request = vi.fn().mockRejectedValue(error);
    await expect(readReleaseState(catalog, before, request)).rejects.toBe(error);
    expect(request).toHaveBeenCalledTimes(1);
    expect(request.mock.calls[0][1]).toEqual({ read_only: true, query: releaseMetadataQuery(before) });
  });

  it('preserves a domain-read failure without retrying either query', async () => {
    const error = new Error('RELEASE_READ_CLIENT_TIMEOUT');
    const request = vi.fn().mockResolvedValueOnce([{ metadata: {} }]).mockRejectedValueOnce(error);
    await expect(readReleaseState(catalog, before, request)).rejects.toBe(error);
    expect(request).toHaveBeenCalledTimes(2);
  });
});

it('uses the serialized read boundary in both actual deployment entry points', () => {
  const preflight = readFileSync(new URL('./redesign-preflight.mjs', import.meta.url), 'utf8');
  const postmigration = readFileSync(new URL('./redesign-postmigration.mjs', import.meta.url), 'utf8');
  expect(preflight).toContain('await readReleaseState(catalog)');
  expect(postmigration).toContain('await readReleaseState(before.catalog,before)');
  expect(preflight).not.toContain('Promise.all(');
  expect(postmigration).not.toContain('Promise.all(');
});
