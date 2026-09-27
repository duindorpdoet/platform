export const avatarOptions = [
  { id: "nightwatcher", label: "Nachtwachter" },
  { id: "little-wizard", label: "Kleine magiër" },
  { id: "ghost-scout", label: "Spookverkenner" },
  { id: "pumpkin-guardian", label: "Pompoenwachter" },
  { id: "shadow-traveler", label: "Schaduwreiziger" },
  { id: "moon-knight", label: "Maanridder" },
] as const;

export const lanternShapes = [
  { id: "classic", label: "Klassieke lantaarn" },
  { id: "moon", label: "Maanlantaarn" },
  { id: "tower", label: "Torenlantaarn" },
  { id: "crystal", label: "Kristallantaarn" },
] as const;

export const lanternColors = [
  { id: "amber", label: "Amber" },
  { id: "cyan", label: "Cyaan" },
  { id: "violet", label: "Paars" },
  { id: "emerald", label: "Smaragd" },
  { id: "rose", label: "Roos" },
  { id: "moonlight", label: "Maanlicht" },
] as const;

export const bannerOptionLabels = {
  shape: {
    shield: "Schild",
    swallowtail: "Zwaluwstaart",
    round: "Rond",
    split: "Gespleten",
  },
  color: {
    amber: "Amber",
    cyan: "Cyaan",
    violet: "Paars",
    emerald: "Smaragd",
    crimson: "Karmozijn",
    moonlight: "Maanlicht",
  },
  secondaryColor: {
    amber: "Amber",
    cyan: "Cyaan",
    violet: "Paars",
    emerald: "Smaragd",
    crimson: "Karmozijn",
    moonlight: "Maanlicht",
  },
  border: { rope: "Koord", metal: "Metaal", thorns: "Doornen", stars: "Sterren" },
  symbol: {
    gate: "Poort",
    moon: "Maan",
    flame: "Vlam",
    ghost: "Spook",
    key: "Sleutel",
    star: "Ster",
    bat: "Vleermuis",
    pumpkin: "Pompoen",
  },
  lantern: {
    classic: "Klassiek",
    moon: "Maan",
    tower: "Toren",
    crystal: "Kristal",
  },
  glow: { warm: "Warme gloed", cold: "Koude gloed", magic: "Magische gloed", mist: "Mistgloed" },
} as const;

export type BannerCategory = keyof typeof bannerOptionLabels;
export type BannerChoices = Record<BannerCategory, string>;

export const storyChapters = [
  { chapter: 1, title: "De wijk ontwaakt", image: "story-01-wijk-ontwaakt.webp" },
  { chapter: 2, title: "De eerste poort", image: "story-02-eerste-poort.webp" },
  { chapter: 3, title: "De schaduwen verzamelen", image: "story-03-schaduwen-verzamelen.webp" },
  { chapter: 4, title: "Het verloren teken", image: "story-04-verloren-teken.webp" },
  { chapter: 5, title: "De laatste poort roept", image: "story-05-laatste-poort.webp" },
  { chapter: 6, title: "De eindshow", image: "story-06-eindshow.webp" },
] as const;

export function bannerUpgradeLevel(visited: number, assigned: number) {
  if (assigned > 0 && visited >= assigned) return 4;
  if (visited >= 5) return 3;
  if (visited >= 3) return 2;
  if (visited >= 1) return 1;
  return 0;
}

export function unlockedChapterNumbers(
  visited: number,
  assigned: number,
  finaleComplete: boolean,
) {
  const result = [1];
  if (visited >= 1) result.push(2);
  if (assigned > 0 && visited * 3 >= assigned) result.push(3);
  if (assigned > 0 && visited * 3 >= assigned * 2) result.push(4);
  if (finaleComplete || (assigned > 0 && visited >= Math.max(assigned - 1, 1))) result.push(5);
  if (finaleComplete) result.push(6);
  return result;
}

export function deterministicChoice(
  eventId: string,
  teamId: string,
  category: string,
  tied: string[],
) {
  if (!tied.length) return null;
  return [...tied].sort((a, b) =>
    `${eventId}:${teamId}:${category}:${a}`.localeCompare(
      `${eventId}:${teamId}:${category}:${b}`,
    ),
  )[0];
}
