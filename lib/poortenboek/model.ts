export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export const LOGIN_ERROR =
  "Deze code konden we niet openen. Controleer de zes tekens en probeer het opnieuw.";
export const SESSION_HOURS = 12;
export const normalizeCode = (code: string) => code.trim().toUpperCase();
export const validCode = (code: string) => /^[A-HJ-NP-Z2-9]{6}$/.test(code);
export const demoEnabled = (
  environment: string | undefined,
  flag: string | undefined,
) => environment === "staging" && flag === "true";
export const checklistLabels = [
  "Warme kleding klaargelegd",
  "Lampje of reflectie mee",
  "Snoeptas klaar",
  "Startafspraak bekeken",
  "Ik blijf bij mijn groep",
  "Ik vraag de groepsleider om hulp als dat nodig is",
] as const;
export const teamNames = [
  "De Nachtlopers",
  "De Poortwachters",
  "De Schaduwzoekers",
  "De Maanjagers",
  "De Duinspoken",
  "De Mistlopers",
  "De Fluistervlammen",
  "De Lantaarnbende",
  "De Spookverkenners",
  "De Vleermuiswacht",
  "De Nachtuilen",
  "De Magische Maskers",
  "De Griezelgidsen",
  "De Pompoenpatrouille",
  "De Donderspoken",
  "De Sterrenzoekers",
  "De Geheime Sleutels",
  "De Maanpoortbende",
  "De Snoepspeurders",
  "De Verdwaalde Schaduwen",
];
export const comingSoon = [
  {
    id: "vaandel",
    status: "coming_soon",
    image: "coming-vaandel",
    title: "Bouw samen jullie vaandel",
    text: "Ieder reisgenootje voegt later een magisch teken toe. Samen maken jullie het vaandel van jullie team.",
  },
  {
    id: "verschijning",
    status: "coming_soon",
    image: "coming-avatar-lantern",
    title: "Kies jouw verschijning",
    text: "Kies later jouw Halloweenverschijning, avonturenrol en de kleur van jouw magische lantaarn.",
  },
  {
    id: "oefenpoort",
    status: "coming_soon",
    image: "coming-practice-gate",
    title: "De oefenpoort ontwaakt binnenkort",
    text: "Leer vóór de tocht hoe een poort opent en hoe een nieuwe zegel in jouw Poortenboek verschijnt.",
  },
] as const;
export const prologue =
  "Wanneer de laatste zonnestraal achter de duinen verdwijnt, ontwaakt iets in de straten van Duindorp. Oude poorten lichten op. Achter iedere deur wacht een andere wereld. Dit boek heeft op jou gewacht. Samen met je reisgenootjes schrijf je het verhaal van één bijzondere nacht.";
export type NameOption = { id: string; label: string };
export type Election = {
  id: string;
  generation: number;
  phase: "direct" | "round_one" | "round_two" | "finished";
  eligibleCount: number;
  votedCount: number;
  options: NameOption[];
  ownChoices: string[];
  winner: string | null;
  magicTiebreak: boolean;
  deadline: string;
  open: boolean;
};
export type BookSnapshot = {
  firstName: string;
  medallion: number;
  expiresAt: string;
  welcomeRequired: boolean;
  demo: boolean;
  eventDate: string;
  eventPhase: string;
  checklist: boolean[];
  soundEnabled: boolean;
  companions: Array<{
    firstName: string;
    medallion: number;
    status: "preparing" | "ready" | "underway" | "completed";
  }>;
  election: Election;
  start: { name: string; startsAt: string } | null;
  worlds: Array<{ slug: string; name: string; story: string }>;
  unlocks: Array<{
    kind: "seal" | "chapter";
    world: string | null;
    earnedAt: string;
  }>;
  updatedAt: string;
};
export type BookSection = "nu" | "team" | "boek" | "ik";
export type DemoPhase =
  "empty" | "three" | "all" | "finalists" | "winner" | "prepared";
export function nightsUntil(date: string, now: number) {
  return Math.max(
    0,
    Math.ceil(
      (new Date(`${date}T00:00:00+01:00`).getTime() - now) / 86_400_000,
    ),
  );
}
export function rankedChoices(choices: string[]) {
  return choices.map((id, index) => ({ id, sparks: 3 - index }));
}
