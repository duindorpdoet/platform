import 'server-only';
import { chapterStories } from './story-content-server';
import type { BookSnapshot } from './model';

/** The browser receives narrative text only for server-authorized chapters. */
export function withBookStories<T>(value: T): T {
  if (!value || typeof value !== 'object' || !('journey' in value)) return value;
  const snapshot = value as unknown as BookSnapshot;
  const unlocked = new Set(snapshot.journey.chapters.map(item => item.chapter));
  return { ...snapshot, reading: { ...snapshot.reading, readChapters: snapshot.reading?.readChapters ?? [], stories: chapterStories.filter(story => unlocked.has(story.chapter)) } } as T;
}
