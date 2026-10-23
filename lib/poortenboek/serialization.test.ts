import { describe, expect, it, vi } from 'vitest';
vi.mock('server-only', () => ({}));
import { withBookStories } from './serialization';
import type { BookSnapshot } from './model';

describe('authorized story serialization', () => {
  it('does not send the sleeping narrative paragraphs to a client', () => {
    const snapshot = { firstName: 'Eigen kind', journey: { chapters: [{ chapter: 1 }], seals: [] } } as unknown as BookSnapshot;
    const result = withBookStories(snapshot);
    expect(result.reading?.stories.map(story => story.chapter)).toEqual([1]);
    expect(JSON.stringify(result)).not.toContain('Toen de laatste poort was bezocht');
  });
  it('does not fill in a missing finale for an early departure', () => {
    const snapshot = { farewell: { reason: 'early' }, journey: { chapters: [], seals: [], complete: false } } as unknown as BookSnapshot;
    const result = withBookStories(snapshot);
    expect(result.journey.complete).toBe(false); expect(result.reading?.stories).toEqual([]);
  });
});
