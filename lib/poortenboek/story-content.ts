/** Friendly story text; presentation never includes a participant address or future route. */
export type StoryChapterContent = {
  chapter: number;
  subtitle: string;
  readingMinutes: number;
  paragraphs: readonly string[];
  wonder: string;
};

export function personalizeStory(text: string, firstName: string): string {
  return text.replaceAll('{naam}', firstName || 'avonturier');
}
