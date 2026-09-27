export const portalRoles = {
  owner: "Hoofdpoortwachter",
  portal_manager: "Poortbeheerder",
  actor: "Acteur",
  reception: "Ontvangst",
  tech: "Techniek",
  coadmin: "Mede-beheerder",
  crew: "Crew/acteur",
  viewer: "Meekijker",
  admin: "Organisatie",
} as const;
export type PortalRole = keyof typeof portalRoles;
export const portalStates = {
  scheduled: "Voorbereiding",
  open: "Open",
  paused: "Pauze",
  closed: "Gestopt",
} as const;
export const stockLabels = {
  plenty: "Ruim voldoende",
  sufficient: "Voldoende",
  low: "Laag",
  empty: "Op",
} as const;
export const readinessItems = [
  ["access", "Toegang en looproute zijn vrij"],
  ["lighting", "Verlichting en kabels zijn veilig"],
  ["crew", "Acteurs en crew zijn aanwezig"],
  ["phone", "Telefoon is opgeladen"],
  ["push", "Pushmeldingen zijn getest"],
  ["qr", "QR-code staat klaar"],
  ["warnings", "Waarschuwingen en toegankelijkheid kloppen"],
  ["opening", "We kunnen op tijd openen"],
] as const;
export const notificationLabels = {
  next_10: "Volgende groep over ongeveer 10 minuten",
  next_3: "Volgende groep over ongeveer 3 minuten",
  arrived: "Een groep heeft het bezoek gescand",
  pause_1: "Pauze eindigt over ongeveer 1 minuut",
  urgent: "Urgente mededelingen",
  mention: "Vermelding in teamchat",
  access: "Wijziging in mijn toegang",
} as const;
export type RoomChannel = {
  id: string;
  name: string;
  kind: "team" | "community" | "announcements";
  unread: number;
  muted: boolean;
};
export type PortalMember = {
  userId: string;
  name: string;
  role: PortalRole;
  task: string | null;
  lastSeenAt: string | null;
  accessLevel: "read" | "live" | "manage";
  suspendedAt: string | null;
};
export type PortalPresentation = {
  id: string;
  version: number;
  status: "draft" | "submitted" | "approved" | "changes_requested" | "rejected" | "active" | "retired";
  publicName: string;
  world: string;
  shortDescription: string;
  story: string;
  symbol: string;
  color: string;
  imagePath: string | null;
  accessibility: string;
  intensity: number;
  reviewNote: string | null;
};
export type PortalIncident = {
  id: string;
  category: "crowding" | "lingering" | "technical" | "nuisance" | "unsafe" | "contact_requested" | "other";
  urgency: "normal" | "high";
  status: "new" | "seen" | "in_progress" | "resolved" | "closed";
  description: string;
  callbackRequested: boolean;
  resolutionMessage: string | null;
  createdAt: string;
};
export type Arrival = {
  groupCode: string;
  plannedArrivalAt: string;
  plannedDepartureAt: string;
  expectedChildren: number;
  state: string;
  classification: string;
};
export type Visit = { groupCode: string; visitedAt: string; children: number };
export type NightRecap = {
  groups: number;
  children: number;
  firstVisit: string | null;
  lastVisit: string | null;
  busiestHalfHour: string | null;
  averageGapMinutes: number | null;
  pauses: number;
  pauseMinutes: number;
};
export type PortalRoom = {
  userId: string;
  eventId: string;
  eventDate: string;
  updatedAt: string;
  role: PortalRole;
  portalTopic: string;
  communityTopic: string;
  portals: Array<{ id: string; code: string; name: string }>;
  portal: {
    id: string;
    code: string;
    name: string;
    description: string;
    world: string;
    worldSlug: string;
    state: keyof typeof portalStates;
    version: number;
    pauseUntil: string | null;
    stock: keyof typeof stockLabels;
    lastActivity: string;
    locationVerified: boolean;
    opensAt: string | null;
    closesAt: string | null;
  };
  team: PortalMember[];
  invites: Array<{
    id: string;
    name: string;
    email: string;
    role: PortalRole;
    status: "pending" | "accepted" | "expired" | "revoked";
    expiresAt: string;
  }>;
  checklist: Array<{
    item: string;
    done: boolean;
    changedAt: string;
    changedBy: string;
  }>;
  channels: RoomChannel[];
  visits: { arrivals: Arrival[]; visits: Visit[]; recap: NightRecap };
  urgentAnnouncement: { id: number; body: string; createdAt: string } | null;
  preferences: Record<keyof typeof notificationLabels, boolean>;
  v2: {
    presentation: PortalPresentation | null;
    presentationVersions: Array<Pick<PortalPresentation, "id" | "version" | "status" | "publicName" | "reviewNote">>;
    incidents: PortalIncident[];
    simulation: {
      id: string;
      phase: "quiet" | "open" | "approaching" | "arrived" | "busy" | "paused" | "stopped" | "incident" | "chat" | "seal" | "finale" | "completed";
      state: "running" | "completed" | "reset";
      updatedAt: string;
      simulation: true;
      scenario: {
        queue: Array<{ groupCode: string; children: number; etaMinutes: number }>;
        visits: number;
        children: number;
        incident: boolean;
        chatTested: boolean;
        sealTested: boolean;
        finaleTested: boolean;
      };
    } | null;
    liveLog: Array<{ groupCode: string; visitedAt: string; children: number }>;
    teamHistory: Array<{
      action: string;
      at: string;
      change: Record<string, unknown>;
    }>;
    simulationLabel: true;
  };
};
export type RoomMessage = {
  mentionUserId?: string | null;
  id: number;
  body: string;
  sender: string;
  role: PortalRole | null;
  portalCode: string | null;
  portalName: string | null;
  system: boolean;
  urgent: boolean;
  pinned: boolean;
  hidden: boolean;
  own: boolean;
  createdAt: string;
  reactions: Array<{ emoji: string; count: number; own: boolean }>;
};
export type ChatSnapshot = {
  channelId: string;
  retainedUntil: string;
  messages: RoomMessage[];
  pins: Array<{ id: number; body: string }>;
};
export function canEditPortal(role: PortalRole) {
  return ["owner", "portal_manager", "coadmin", "admin"].includes(role);
}
export function canManageTeam(role: PortalRole) {
  return role === "owner" || role === "admin";
}
export function roomMetrics(room: PortalRoom, now = Date.now()) {
  const upcoming = [...room.visits.arrivals].sort(
    (a, b) => Date.parse(a.plannedArrivalAt) - Date.parse(b.plannedArrivalAt),
  );
  return {
    next: upcoming[0] ?? null,
    remainingGroups: upcoming.length,
    remainingChildren: upcoming.reduce((sum, a) => sum + a.expectedChildren, 0),
    nextHalfHour: upcoming.filter(
      (a) =>
        Date.parse(a.plannedArrivalAt) >= now &&
        Date.parse(a.plannedArrivalAt) <= now + 30 * 60_000,
    ).length,
    ready: readinessItems.filter(([key]) =>
      room.checklist.some((item) => item.item === key && item.done),
    ).length,
  };
}
export function portalTime(value: string | null | undefined) {
  return value
    ? new Intl.DateTimeFormat("nl-NL", {
        hour: "2-digit",
        minute: "2-digit",
        timeZone: "Europe/Amsterdam",
      }).format(new Date(value))
    : "Nog niet bekend";
}
export function roomError(message: string) {
  if (message.includes("NOT_AUTHORIZED"))
    return "Je hebt geen toegang meer tot deze handeling. De actuele rechten zijn opgehaald.";
  if (message.includes("RATE_LIMITED"))
    return "Je doet dit te snel achter elkaar. Wacht een minuut en probeer opnieuw.";
  if (
    message.includes("ALREADY_MEMBER") ||
    message.includes("portal_pending_invite")
  )
    return "Dit teamlid heeft al toegang of een openstaande uitnodiging.";
  if (message.includes("STALE_VERSION"))
    return "De poort is intussen gewijzigd. Bekijk de actuele gegevens en probeer opnieuw.";
  if (message.includes("COMMUNITY_MUTED"))
    return "De organisatie heeft het plaatsen op het Poortplein tijdelijk gepauzeerd voor jouw account. Je teamchat blijft beschikbaar.";
  return "De wijziging is niet bevestigd. Controleer je verbinding en probeer opnieuw.";
}
