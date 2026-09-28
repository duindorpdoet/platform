export const shareFormats = {
  story: { label: "Story", width: 1080, height: 1920, source: "portrait" },
  feed: { label: "Feed", width: 1080, height: 1350, source: "portrait" },
  square: { label: "Vierkant", width: 1080, height: 1080, source: "portrait" },
  landscape: { label: "Liggend", width: 1600, height: 900, source: "landscape" },
  opengraph: { label: "Open Graph", width: 1200, height: 630, source: "landscape" },
} as const;

export type ShareFormat = keyof typeof shareFormats;
export type ShareStyle = "event" | "world";
export type ShareTemplateKey =
  | "participant"
  | "gate_owner"
  | "join_us"
  | "recruit_gate"
  | "recruit_helper"
  | "team_reveal"
  | "world_reveal"
  | "countdown"
  | "participant_recap"
  | "gate_recap"
  | "general_event";

export type ShareDynamic = {
  eventTitle?: string;
  eventDate?: string;
  timezone?: string;
  teamName?: string;
  portalName?: string;
  worldName?: string;
  worldColor?: string;
  banner?: Record<string, unknown>;
  visitedCount?: number;
  receivedGroups?: number;
  estimatedVisitors?: number;
  nightsRemaining?: number;
};

export type ShareTextConfig = {
  eyebrow?: string;
  title?: string;
  subtitle?: string;
  date?: string;
  publicDescription?: string;
  publicEventPath?: string;
  houseRegistrationPath?: string;
};

export type ShareCard = {
  key: ShareTemplateKey;
  name: string;
  version: number;
  formats: ShareFormat[];
  portraitAsset: string;
  landscapeAsset: string;
  textConfig: ShareTextConfig;
  defaultCaption: string;
  ctaType: "event" | "registration" | "house_registration";
  dynamic: ShareDynamic;
  worldStyleAvailable: boolean;
};

export type ShareContext = {
  event: { title: string; localDate: string; timezone: string };
  authenticated: boolean;
  cards: ShareCard[];
};

export const personalTemplateKeys = new Set<ShareTemplateKey>([
  "participant",
  "gate_owner",
  "join_us",
  "recruit_helper",
  "team_reveal",
  "world_reveal",
  "participant_recap",
  "gate_recap",
]);

export function isShareFormat(value: string): value is ShareFormat {
  return Object.hasOwn(shareFormats, value);
}
export function interpolateShareText(
  value: string,
  dynamic: ShareDynamic,
  publicOrigin: string,
  houseRegistrationPath = "/huis-aanmelden",
) {
  const replacements: Record<string, string> = {
    public_event_url: publicOrigin,
    house_registration_url: new URL(houseRegistrationPath, publicOrigin).href,
    safe_team_name: dynamic.teamName ?? "ons team",
    public_gate_name_optional: dynamic.portalName ?? "onze Poort",
    world_name: dynamic.worldName ?? "een mysterieuze wereld",
    nights_remaining: String(dynamic.nightsRemaining ?? 0),
  };
  return value.replace(/\{\{([a-z_]+)\}\}/g, (_, key: string) => replacements[key] ?? "");
}

export function privacySafeSerialized(value: unknown) {
  const serialized = JSON.stringify(value).toLowerCase();
  return ![
    "togethercode",
    "invite_token",
    "invitecode",
    "childname",
    "firstname",
    "email",
    "phone",
    "address",
    "startslot",
    "starttime",
    "startpoint",
    "laatste poort",
    "eindpoort",
  ].some((term) => serialized.includes(term));
}
