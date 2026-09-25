export type ActivityTone = "success" | "info" | "warning";

export type ActivityPresentation = {
  message: string;
  source: string;
  tone: ActivityTone;
};

export const activityActionLabels: Record<string, string> = {
  "content.draft_created": "Nieuw contentconcept aangemaakt",
  "content.published": "Content gepubliceerd",
  "event.capabilities_changed": "Beheerrechten bijgewerkt",
  "event.emergency_closure_activated": "Noodsluiting geactiveerd",
  "event.first_admin_bootstrapped": "Eerste beheerder ingesteld",
  "group.created": "Nieuwe groep aangemaakt",
  "group.destination_redirected": "Groep naar een andere poort gestuurd",
  "group.journey_preference_updated": "Routevoorkeur van groep bijgewerkt",
  "group.leader_reassigned": "Hoofdcontact van groep gewijzigd",
  "group.name_updated": "Groepsnaam bijgewerkt",
  "group.registration_moved": "Inschrijving naar een andere groep verplaatst",
  "group.safe_departure_recorded": "Veilig vertrek van groep vastgelegd",
  "group.viewer_access_accepted": "Meekijktoegang geaccepteerd",
  "group.viewer_access_revoked": "Meekijktoegang ingetrokken",
  "group.viewer_invite_revoked": "Uitnodiging voor meekijken ingetrokken",
  "group.viewer_invited": "Meekijker uitgenodigd",
  "group_schedule.proposal_saved": "Voorstel voor groepsplanning opgeslagen",
  "group_schedule.published": "Groepsplanning gepubliceerd",
  "group_schedule.revision_created": "Nieuwe versie van groepsplanning gemaakt",
  "group_size_limit.updated": "Maximale groepsgrootte bijgewerkt",
  "group_ticket.created": "Nieuw groepsbericht ontvangen",
  "group_ticket.replied": "Reactie op groepsbericht verstuurd",
  "group_ticket.status_changed": "Status van groepsbericht gewijzigd",
  "household.invite_accepted": "Uitnodiging voor huishouden geaccepteerd",
  "household.invite_created": "Uitnodiging voor huishouden verstuurd",
  "household.invite_revoked": "Uitnodiging voor huishouden ingetrokken",
  "household.member_revoked": "Toegang van huishoudlid ingetrokken",
  "import.dry_run_recorded": "Importcontrole uitgevoerd",
  "messenger.admin.create": "Organisatiegesprek gestart",
  "messenger.admin.reply": "Organisatie heeft op gesprek gereageerd",
  "messenger.admin_started": "Organisatie heeft gesprek geopend",
  "messenger.closed": "Gesprek gesloten",
  "messenger.conversation_started": "Nieuw gesprek gestart",
  "messenger.participant.create": "Nieuw deelnemersgesprek ontvangen",
  "messenger.participant.reply": "Nieuwe reactie van deelnemer ontvangen",
  "participant.departed": "Groep vertrokken",
  "participant.preferences_updated": "Voorkeuren van deelnemer bijgewerkt",
  "participant.update_published": "Update voor deelnemers gepubliceerd",
  "participants.bulk_skipped": "Deelnemersupdate deels overgeslagen",
  "payment.batch_cancelled": "Gezamenlijk Tikkie ingetrokken",
  "payment.batch_cancelled_for_child_change": "Tikkie ingetrokken na wijziging van kinderen",
  "payment.batch_cancelled_for_child_removal": "Tikkie ingetrokken na verwijderen van kind",
  "payment.batch_confirmed": "Gezamenlijke betaling bevestigd",
  "payment.batch_published": "Gezamenlijk Tikkie verstuurd",
  "payment.child_batch_cancelled_for_child_removal": "Tikkie voor kinderen ingetrokken",
  "payment.child_cancelled": "Tikkie voor kind ingetrokken",
  "payment.child_confirmed": "Betaling voor kind bevestigd",
  "payment.child_marked_unpaid": "Kind als niet betaald gemarkeerd",
  "payment.child_published": "Tikkie voor kind verstuurd",
  "payment.child_refunded": "Betaling voor kind terugbetaald",
  "payment.child_reported": "Betaling voor kind gemeld",
  "payment.confirm": "Betalingsbevestiging gestart",
  "payment.confirmed": "Betaling bevestigd",
  "payment.external_link_set": "Tikkie-link toegevoegd",
  "payment.legacy_link_withdrawn": "Eerdere Tikkie-link ingetrokken",
  "payment.refund": "Terugbetaling gestart",
  "payment.refunded": "Betaling terugbetaald",
  "portal.credential_rotated": "Nieuwe toegangscode voor poort gemaakt",
  "portal.location_verified": "Locatie van poort geverifieerd",
  "portal.operation_state_changed": "Ontvangststatus van poort gewijzigd",
  "portal.submit": "Poortaanmelding ingediend",
  "portal_application.approved": "Poortaanmelding goedgekeurd",
  "portal_application.submitted": "Nieuwe poortaanmelding ontvangen",
  "portal_registration.claimed": "Poortomgeving geactiveerd",
  "registration.change_applied": "Wijziging van inschrijving verwerkt",
  "registration.change_rejected": "Wijziging van inschrijving afgewezen",
  "registration.change_requested": "Wijziging van inschrijving aangevraagd",
  "registration.child_added_by_parent": "Kind aan inschrijving toegevoegd",
  "registration.child_removed_by_parent": "Kind uit inschrijving verwijderd",
  "registration.correction_resolved": "Correctie van inschrijving afgerond",
  "registration.exact_preference_change_requested": "Wijziging van tijdvoorkeur aangevraagd",
  "registration.exact_preferences_updated": "Tijdvoorkeuren bijgewerkt",
  "registration.preference_change_requested": "Wijziging van voorkeuren aangevraagd",
  "registration.preferences_updated": "Voorkeuren van inschrijving bijgewerkt",
  "registration.submit": "Inschrijving ingediend",
  "registration.submitted": "Nieuwe inschrijving ontvangen",
  "registration_channel.updated": "Beschikbaarheid van inschrijven gewijzigd",
  "release.mode_configured": "Inschrijfmodus ingesteld",
  "release.notification_recipient_configured": "Ontvanger voor organisatiemeldingen ingesteld",
  "route_plan.proposal_saved": "Routevoorstel opgeslagen",
  "route_plan.published": "Routeplanning gepubliceerd",
  "route_plan.revision_created": "Nieuwe versie van routeplanning gemaakt",
  "route_settings.updated": "Route-instellingen bijgewerkt",
  "run.ready": "Groep klaargezet voor vertrek",
  "run.start": "Vertrek van groep gestart",
  "run.started": "Groep is gestart",
  "run.live": "Groep is onderweg",
  "run.paused": "Groep gepauzeerd",
  "run.completed": "Route van groep afgerond",
  "run.stopped": "Route van groep gestopt",
  "sponsor.published": "Sponsor gepubliceerd",
  "start_point.saved": "Startpunt opgeslagen",
  "start_slot.saved": "Starttijd opgeslagen",
  "stop.admin_redirected": "Bestemming door organisatie gewijzigd",
  "stop.completed": "Bezoek aan poort bevestigd",
  "stop.cutoff_redirected": "Route aangepast vanwege eindtijd",
  "stop.dispatched": "Volgende poort toegewezen",
  "stop.emergency_interrupted": "Bezoek vanwege noodsluiting afgebroken",
  "stop.reservation_expired": "Reservering van poort verlopen",
  "stop.scanned": "QR-code bij poort gescand",
  "stop.support_override": "Bezoek handmatig aangepast",
  "stop.system_skipped": "Poort automatisch overgeslagen",
  "together.capacity_request_accepted": "Aanvraag voor grotere samenloopgroep goedgekeurd",
  "together.capacity_request_rejected": "Aanvraag voor grotere samenloopgroep afgewezen",
  "together.capacity_review_requested": "Controle van groepscapaciteit aangevraagd",
  "together.join_requested": "Samenloopverzoek ontvangen",
  "together.join_withdrawn": "Samenloopverzoek ingetrokken",
  "together_party.created": "Samenloopgroep aangemaakt",
  "together_party.joined": "Inschrijving aan samenloopgroep gekoppeld",
  "together_party.left": "Inschrijving uit samenloopgroep gehaald",
};

export const activitySourceLabels: Record<string, string> = {
  child_payment_batch: "Tikkie voor kind",
  content_revision: "Websitecontent",
  event: "Evenement",
  group: "Groep",
  group_run: "Avondroute",
  group_schedule: "Groepsplanning",
  group_ticket: "Groepsgesprek",
  household: "Huishouden",
  import_run: "Import",
  messenger_conversation: "Messenger",
  participant: "Deelnemer",
  participant_update: "Deelnemersupdate",
  payment_batch: "Gezamenlijk Tikkie",
  payment_request: "Betaling",
  portal: "Poort",
  portal_application: "Poortaanmelding",
  portal_registration: "Poortomgeving",
  registration: "Inschrijving",
  registration_change_request: "Wijzigingsverzoek",
  route_plan: "Routeplanning",
  sponsor: "Sponsor",
  start_point: "Startpunt",
  start_slot: "Starttijd",
  stop: "Routebezoek",
  together_join_request: "Samenloopverzoek",
  together_party: "Samenloopgroep",
  user_role: "Beheerderstoegang",
};

const wordLabels: Record<string, string> = {
  accepted: "geaccepteerd",
  action: "actie",
  added: "toegevoegd",
  admin: "organisatie",
  approved: "goedgekeurd",
  batch: "verzameling",
  cancelled: "ingetrokken",
  changed: "gewijzigd",
  check: "controle",
  child: "kind",
  closed: "gesloten",
  completed: "afgerond",
  configured: "ingesteld",
  confirmed: "bevestigd",
  created: "aangemaakt",
  departed: "vertrokken",
  draft: "concept",
  emergency: "nood",
  event: "evenement",
  extra: "extra",
  group: "groep",
  invite: "uitnodiging",
  joined: "gekoppeld",
  legacy: "eerder",
  link: "link",
  location: "locatie",
  marked: "gemarkeerd",
  message: "bericht",
  notification: "melding",
  operation: "ontvangst",
  participant: "deelnemer",
  paused: "gepauzeerd",
  payment: "betaling",
  portal: "poort",
  preference: "voorkeur",
  published: "gepubliceerd",
  recipient: "ontvanger",
  refunded: "terugbetaald",
  registration: "inschrijving",
  rejected: "afgewezen",
  removed: "verwijderd",
  reply: "reactie",
  requested: "aangevraagd",
  resolved: "afgerond",
  route: "route",
  saved: "opgeslagen",
  scanned: "gescand",
  started: "gestart",
  status: "status",
  submitted: "ontvangen",
  together: "samenloop",
  unpaid: "niet betaald",
  updated: "bijgewerkt",
  verified: "geverifieerd",
  withdrawn: "ingetrokken",
};

const subjectLabels: Record<string, string> = {
  content: "Content",
  event: "Evenement",
  group: "Groep",
  group_schedule: "Groepsplanning",
  group_ticket: "Groepsgesprek",
  household: "Huishouden",
  import: "Import",
  messenger: "Messenger",
  participant: "Deelnemer",
  participants: "Deelnemers",
  payment: "Betaling",
  portal: "Poort",
  portal_application: "Poortaanmelding",
  portal_registration: "Poortomgeving",
  registration: "Inschrijving",
  registration_channel: "Inschrijven",
  release: "Publicatie",
  route_plan: "Routeplanning",
  route_settings: "Route-instellingen",
  run: "Groep",
  sponsor: "Sponsor",
  start_point: "Startpunt",
  start_slot: "Starttijd",
  stop: "Routebezoek",
  together: "Samenloopverzoek",
  together_party: "Samenloopgroep",
};

function capitalize(value: string) {
  return value ? value.charAt(0).toUpperCase() + value.slice(1) : value;
}

function humanizeWords(value: string) {
  return value
    .split(/[_-]+/)
    .filter(Boolean)
    .map((word) => wordLabels[word] ?? word)
    .join(" ");
}

export function activityMessage(action: string) {
  const normalized = action.trim().toLowerCase();
  if (!normalized) return "Activiteit bijgewerkt";
  if (activityActionLabels[normalized]) return activityActionLabels[normalized];

  const [subject, ...operations] = normalized.split(".");
  const subjectLabel = subjectLabels[subject] ?? capitalize(humanizeWords(subject));
  const operationLabel = humanizeWords(operations.join("_"));
  return operationLabel ? `${subjectLabel}: ${capitalize(operationLabel)}` : `${subjectLabel} bijgewerkt`;
}

export function activitySource(resourceType: string) {
  const normalized = resourceType.trim().toLowerCase();
  if (!normalized) return "Systeem";
  return activitySourceLabels[normalized] ?? capitalize(humanizeWords(normalized));
}

export function activityTone(action: string): ActivityTone {
  const normalized = action.toLowerCase();
  if (/(rejected|cancelled|revoked|closed|interrupted|skipped|expired|withdrawn|unpaid|stopped)/.test(normalized)) return "warning";
  if (/(approved|accepted|confirmed|completed|scanned|departed|joined|published|applied|resolved|started|submitted)/.test(normalized)) return "success";
  return "info";
}

export function normalizeActivity(action: string, resourceType: string): ActivityPresentation {
  return {
    message: activityMessage(action),
    source: activitySource(resourceType),
    tone: activityTone(action),
  };
}
