import type { MailDetail, PremiumMailBrand, PremiumMailContent } from "./premium-template";
import { validatedTikkieUrl } from "./tikkie-url";

export const MAIL_MESSAGE_TYPES = [
  "auth_otp",
  "auth_email_change",
  "auth_email_change_new",
  "registration_received",
  "payment_link_ready",
  "payment_reminder",
  "payment_reported",
  "payment_confirmed",
  "payment_deadline_missed",
  "household_invite",
  "group_viewer_invite",
  "group_merge_requested",
  "group_merge_approved",
  "group_merge_declined",
  "group_schedule_published",
  "group_schedule_corrected",
  "stops_request_received",
  "stops_request_admin",
  "stops_request_resolved",
  "event_reminder",
  "urgent_group_notice",
  "portal_registered",
  "portal_received",
  "portal_changes_requested",
  "portal_approved",
  "portal_rejected",
  "contact_received",
  "contact_notification",
  "sponsor_received",
  "sponsor_notification",
  "group_ticket_message_organization",
  "group_ticket_message_leader",
  "messenger_incoming_admin",
  "messenger_admin_reply",
  "participant_update",
] as const;

export type MailMessageType = typeof MAIL_MESSAGE_TYPES[number];

export class UnknownMailTemplateError extends Error {
  readonly code = "UNKNOWN_TEMPLATE";

  constructor(messageType: string) {
    super(`Unknown transactional mail template: ${messageType}`);
    this.name = "UnknownMailTemplateError";
  }
}

type Payload = Record<string, unknown>;
type CatalogDefinition = Omit<PremiumMailContent, "paragraphs" | "primaryAction" | "details" | "code" | "reference"> & {
  paragraphs: (payload: Payload) => string[];
  action?: { label: string; path: string };
};

const CATALOG: Record<MailMessageType, CatalogDefinition> = {
  auth_otp: {
    kind: "otp", subject: "Je code voor De Duindorpse Poorten", preheader: "Je code voor toegang tot je persoonlijke omgeving.", eyebrow: "Een veilige toegang", title: "De poort gaat voor je open.",
    paragraphs: () => ["Vul de code hieronder in op de pagina waar je hem aanvroeg. Deel deze code met niemand."],
    footerReason: "Je ontvangt deze e-mail vanwege een verificatie- of inlogverzoek.",
  },
  auth_email_change: {
    kind: "otp", subject: "Bevestig de wijziging van je e-mailadres", preheader: "Gebruik deze code om de wijziging op je huidige adres goed te keuren.", eyebrow: "Beveiliging van je account", title: "Controle op je huidige adres.",
    paragraphs: () => ["Er is gevraagd om het e-mailadres van je account te wijzigen. Gebruik deze code als jij de wijziging hebt aangevraagd. Was jij dit niet? Deel de code niet en neem contact op met de organisatie."],
    footerReason: "Je ontvangt deze e-mail op je huidige adres vanwege een aangevraagde e-mailwijziging.",
  },
  auth_email_change_new: {
    kind: "otp", subject: "Bevestig je nieuwe e-mailadres", preheader: "Gebruik deze code om je nieuwe e-mailadres te bevestigen.", eyebrow: "Beveiliging van je account", title: "Controle op je nieuwe adres.",
    paragraphs: () => ["Gebruik onderstaande code om te bevestigen dat je toegang hebt tot dit nieuwe e-mailadres. Heb je geen wijziging aangevraagd? Deel de code niet en neem contact op met de organisatie."],
    footerReason: "Je ontvangt deze e-mail op je nieuwe adres vanwege een aangevraagde e-mailwijziging.",
  },
  registration_received: {
    kind: "confirmation", subject: "Jullie inschrijving is ontvangen", preheader: "Je inschrijving staat klaar; betaling en starttijd volgen apart.", eyebrow: "Jullie avontuur begint", title: "De eerste stap is gezet.", hero: true,
    paragraphs: (payload) => [`${greeting(payload)}we hebben jullie inschrijving ontvangen. De betaling en de startindeling bevestigen we afzonderlijk. Je vindt de actuele stand altijd in jullie omgeving.`, "De bijdrage is bedoeld om waar nodig snoep te verdelen onder de deelnemende huizen."],
    action: { label: "Bekijk jullie inschrijving", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt deze bevestiging naar aanleiding van jullie inschrijving.",
  },
  payment_link_ready: {
    kind: "payment", subject: "De betaling voor jullie groep staat klaar", preheader: "Betaal vóór 30 oktober om mee te kunnen lopen.", eyebrow: "Betaling van je groep", title: "Nog één stap tot de avond.",
    paragraphs: (payload) => validatedTikkieUrl(payload.externalUrl)
      ? [
          `${greeting(payload)}de Tikkie-link voor jullie inschrijving staat klaar. Hieronder zie je het totale bedrag en voor wie deze betaling bedoeld is.`,
          text(payload, ["payerName"])
            ? `${text(payload, ["payerName"])} regelt deze gezamenlijke betaling voor alle hieronder genoemde gezinnen. Betaal het totaalbedrag één keer; de andere gezinnen hoeven niet afzonderlijk te betalen.`
            : "Dit is één gezamenlijke betaling voor alle hieronder genoemde gezinnen. Spreek samen af wie het totaalbedrag betaalt; ieder gezin hoeft deze link dus niet afzonderlijk te betalen.",
          "De bijdrage is bedoeld om waar nodig snoep te verdelen onder de deelnemende huizen. Je kunt de betaling ook terugvinden in jullie persoonlijke omgeving.",
        ]
      : [`${greeting(payload)}voor ${groupName(payload)} is de betaling nu beschikbaar. Open jullie beveiligde omgeving voor het juiste bedrag en de betaalinstructie.`],
    notice: { title: "Uiterste betaalmoment", text: "De betaling moet vóór 30 oktober zijn voldaan; zonder tijdige betaling is deelname niet mogelijk." },
    action: { label: "Bekijk de betaling", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt dit bericht omdat er voor jouw inschrijving een betaling klaarstaat.",
  },
  payment_reminder: {
    kind: "reminder", subject: "Herinnering: betaling voor jullie groep", preheader: "Voor 30 oktober betalen is nodig om deel te nemen.", eyebrow: "Een kleine herinnering", title: "Controleer jullie betaling.",
    paragraphs: (payload) => [`${greeting(payload)}volgens onze administratie staat de betaling voor ${groupName(payload)} nog open. Is de betaling net gedaan? Controleer eerst de actuele status in jullie omgeving.`],
    notice: { title: "Belangrijk", text: "Betaal vóór 30 oktober. Na de uiterste datum kan jullie groep niet deelnemen als de betaling niet is bevestigd." },
    action: { label: "Controleer betaalstatus", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt deze herinnering vanwege een nog openstaande betaling.",
  },
  payment_reported: {
    kind: "payment", subject: "Je betaalmelding is binnen", preheader: "De organisatie controleert de betaling nog.", eyebrow: "Betaling in controle", title: "We hebben je melding ontvangen.",
    paragraphs: (payload) => [`${greeting(payload)}je melding over de betaling van ${groupName(payload)} is ontvangen. Dit is nog geen bevestiging dat de betaling is verwerkt. Je krijgt apart bericht zodra dat is gecontroleerd.`],
    action: { label: "Bekijk de status", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt dit bericht omdat je een betaalmelding hebt gedaan.",
  },
  payment_confirmed: {
    kind: "payment", subject: "De betaling is bevestigd", preheader: "Jullie betaling is verwerkt; de startindeling volgt.", eyebrow: "Alles geregeld", title: "Jullie deelname is betaald.",
    paragraphs: (payload) => [`${greeting(payload)}de betaling voor ${groupName(payload)} is bevestigd. Fijn dat jullie erbij zijn. De starttijd en het startpunt ontvang je apart zodra de organisatie de indeling heeft gepubliceerd.`],
    action: { label: "Bekijk jullie deelname", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt deze bevestiging na de registratie van jullie betaling.",
  },
  payment_deadline_missed: {
    kind: "payment", subject: "Jullie deelname kan niet doorgaan", preheader: "De betaling was niet op tijd bevestigd.", eyebrow: "Status van je inschrijving", title: "Een bericht dat we liever niet sturen.",
    paragraphs: (payload) => [`${greeting(payload)}voor ${groupName(payload)} is vóór 30 oktober geen bevestigde betaling geregistreerd. Daarom is jullie deelname voor deze editie vervallen. Denk je dat de betaling wel op tijd is verwerkt? Neem dan via de beveiligde omgeving contact op.`],
    action: { label: "Bekijk de inschrijving", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt dit bericht vanwege een wijziging in de status van jullie inschrijving.",
  },
  household_invite: {
    kind: "group", subject: "Je bent uitgenodigd voor jullie deelname", preheader: "Gebruik dit e-mailadres om toegang te krijgen.", eyebrow: "Samen regelen", title: "Je bent uitgenodigd.",
    paragraphs: () => ["Iemand uit jullie huishouden heeft je uitgenodigd om mee te kijken en praktische zaken te regelen. Open de persoonlijke uitnodiging en log in met precies dit e-mailadres. Deel de uitnodigingslink niet met anderen."],
    action: { label: "Bekijk mijn uitnodiging", path: "/mijn-inschrijving" }, footerReason: "Je ontvangt deze persoonlijke uitnodiging omdat een huishouden je heeft toegevoegd.",
  },
  group_viewer_invite: {
    kind: "group", subject: "Volg jullie groep tijdens de tocht", preheader: "Persoonlijke uitnodiging voor beperkte groepstoegang.", eyebrow: "Een plek om mee te kijken", title: "Je bent welkom als meekijker.",
    paragraphs: (payload) => [`Je bent uitgenodigd om de voortgang van ${groupName(payload)} te volgen. Toekomstige poortadressen en persoonsgegevens van kinderen verschijnen niet in jouw overzicht. Open de uitnodiging met het e-mailadres waarop je dit bericht ontvangt.`],
    action: { label: "Bekijk de uitnodiging", path: "/omgeving/meekijker" }, footerReason: "Je ontvangt dit bericht omdat je voor deze groep bent uitgenodigd.",
  },
  group_merge_requested: {
    kind: "group", subject: "Aanvraag om samen te lopen", preheader: "Jullie groepen zijn nog niet samengevoegd.", eyebrow: "Samen door de wijk", title: "Er wil een groep aansluiten.",
    paragraphs: (payload) => [`Er is een aanvraag om aan te sluiten bij ${groupName(payload)}. De hoofdgroep en de organisatie controleren eerst de beschikbare capaciteit en de voorwaarden. Tot bevestiging blijven beide groepen zelfstandig.`],
    action: { label: "Bekijk de aanvraag", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt dit bericht vanwege een aanvraag om twee groepen samen te voegen.",
  },
  group_merge_approved: {
    kind: "group", subject: "Jullie lopen voortaan samen", preheader: "De hoofdgroep is leidend voor start en route.", eyebrow: "Samen is de wijk mooier", title: "Jullie groepen zijn één groep.",
    paragraphs: (payload) => [`De samenvoeging met ${headGroup(payload)} is bevestigd. Iedereen loopt als één groep vanaf de start en volgt dezelfde actuele poorten. Bekijk de nieuwe groepssamenstelling en jullie startgegevens in de omgeving.`],
    action: { label: "Bekijk onze groep", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt deze bevestiging omdat jouw groep is samengevoegd.",
  },
  group_merge_declined: {
    kind: "group", subject: "De groepen blijven afzonderlijk", preheader: "Je eigen inschrijving blijft gewoon bestaan.", eyebrow: "Update over jullie aanvraag", title: "Deze keer lopen jullie apart.",
    paragraphs: (payload) => [`De aanvraag om bij ${headGroup(payload)} aan te sluiten kon niet worden bevestigd. Je eigen groep en inschrijving blijven bestaan. Bekijk jullie actuele gegevens in de omgeving.`],
    action: { label: "Bekijk mijn groep", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt dit bericht omdat een samenvoegingsaanvraag is beoordeeld.",
  },
  group_schedule_published: {
    kind: "route", subject: "Jullie startpunt en starttijd zijn bekend", preheader: "Bekijk wanneer en waar jullie groep begint.", eyebrow: "Jullie avond", title: "De start staat vast.", hero: true,
    paragraphs: (payload) => [`${greeting(payload)}de organisatie heeft de start van ${groupName(payload)} bevestigd. Kom pas vanaf de toegewezen tijd en meld jullie aanwezigheid in de app. Na de grens voor gewone poorten volgt nog de laatste poort.`],
    action: { label: "Bekijk jullie start", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt deze e-mail omdat de startindeling van jouw groep is gepubliceerd.",
  },
  group_schedule_corrected: {
    kind: "route", subject: "Belangrijk: jullie start is aangepast", preheader: "Gebruik de nieuwe gegevens in dit bericht.", eyebrow: "Nieuwe startgegevens", title: "Jullie indeling is bijgewerkt.",
    paragraphs: (payload) => [`${greeting(payload)}gebruik vanaf nu uitsluitend de bijgewerkte startgegevens van ${groupName(payload)}. Eerder ontvangen gegevens zijn niet meer geldig.`],
    action: { label: "Bekijk de actuele start", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt deze correctie omdat de gepubliceerde start van jouw groep is gewijzigd.",
  },
  stops_request_received: {
    kind: "group", subject: "Je aanvraag voor extra poorten is binnen", preheader: "De organisatie bekijkt of er ruimte is.", eyebrow: "Aanvraag ontvangen", title: "We bekijken wat mogelijk is.",
    paragraphs: (payload) => [`De aanvraag van ${groupName(payload)} voor ${requestedStops(payload)} is ontvangen. Tot een besluit blijft de huidige afspraak gelden.`],
    action: { label: "Bekijk de aanvraag", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt dit bericht omdat jouw groep een aanvraag heeft ingediend.",
  },
  stops_request_admin: {
    kind: "admin", subject: "Een groep vraagt extra poorten aan", preheader: "Open de cockpit om de aanvraag te beoordelen.", eyebrow: "Actie voor de organisatie", title: "Een aanvraag wacht op je besluit.",
    paragraphs: (payload) => [`${groupName(payload)} vraagt ${requestedStops(payload)} aan. Controleer de actuele tijd, beschikbare poorten en de veilige aankomst bij de laatste poort voordat je beslist.`],
    action: { label: "Open de cockpit", path: "/admin" }, footerReason: "Je ontvangt dit bericht omdat je aanvragen voor de avond beheert.",
  },
  stops_request_resolved: {
    kind: "group", subject: "Besluit over jullie extra poorten", preheader: "Bekijk het actuele besluit en de toelichting.", eyebrow: "Aanvraag beoordeeld", title: "Er is een besluit.",
    paragraphs: (payload) => [`De aanvraag van ${groupName(payload)} is ${decision(payload)}. ${explanation(payload)}`],
    action: { label: "Bekijk jullie groep", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt dit bericht omdat de organisatie jullie aanvraag heeft beoordeeld.",
  },
  event_reminder: {
    kind: "reminder", subject: "Jullie Halloweenavond komt dichterbij", preheader: "Bekijk het startpunt en de praktische informatie.", eyebrow: "Bijna zover", title: "De wijk wacht op jullie.", hero: true,
    paragraphs: (payload) => [`${greeting(payload)}de deelname van ${groupName(payload)} is bevestigd. Bekijk vóór vertrek jullie gepubliceerde startpunt, starttijd en praktische informatie in de beveiligde omgeving.`],
    action: { label: "Bekijk de avond", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt deze herinnering omdat jouw groep definitief deelneemt.",
  },
  urgent_group_notice: {
    kind: "route", subject: "Belangrijke wijziging voor jullie tocht", preheader: "Open de app voor de actuele aanwijzing.", eyebrow: "Belangrijke update", title: "Controleer de actuele aanwijzing.",
    paragraphs: (payload) => [`Voor ${groupName(payload)} geldt een belangrijke wijziging. ${summary(payload)} Open de app voordat jullie verderlopen.`],
    action: { label: "Open de actuele route", path: "/omgeving/meeloper" }, footerReason: "Je ontvangt dit bericht omdat deze wijziging jouw groep raakt.",
  },
  portal_registered: {
    kind: "host", subject: "Je huis staat geregistreerd", preheader: "Log in met je code en vul de details in wanneer het past.", eyebrow: "Welkom als poort", title: "Je huis heeft een veilige plek.",
    paragraphs: (payload) => [`${greeting(payload)}je eerste huisregistratie is gekoppeld aan je geverifieerde account. Vul in Mijn huis de overige gegevens aan wanneer het past.`],
    action: { label: "Vul je huisgegevens aan", path: "/omgeving/huiseigenaar" }, footerReason: "Je ontvangt dit bericht omdat je huisregistratie aan je account is gekoppeld.",
  },
  portal_received: {
    kind: "host", subject: "Je poortaanmelding is ingediend", preheader: "De organisatie beoordeelt de gegevens van je huis.", eyebrow: "Gegevens ontvangen", title: "Je poort gaat naar de organisatie.",
    paragraphs: (payload) => [`${greeting(payload)}we hebben de volledige gegevens van je poort ontvangen. De organisatie beoordeelt de aanmelding. Een inzending is nog geen definitieve deelname.`],
    action: { label: "Bekijk mijn poort", path: "/omgeving/huiseigenaar" }, footerReason: "Je ontvangt deze bevestiging omdat je poortgegevens zijn ingediend.",
  },
  portal_changes_requested: {
    kind: "host", subject: "Nog een kleine stap voor je poort", preheader: "Bekijk de opmerkingen van de organisatie.", eyebrow: "Aanvulling gevraagd", title: "We hebben nog iets nodig.",
    paragraphs: (payload) => [`${greeting(payload)}de organisatie heeft gevraagd om je huisgegevens aan te passen. Bekijk de toelichting in je beveiligde huisomgeving; gevoelige gegevens staan niet in deze e-mail.`],
    action: { label: "Bekijk de opmerkingen", path: "/omgeving/huiseigenaar" }, footerReason: "Je ontvangt dit bericht omdat de beoordeling van je poort om een aanvulling vraagt.",
  },
  portal_approved: {
    kind: "host", subject: "Jouw poort is goedgekeurd", preheader: "Bekijk jouw gegevens en maak je klaar voor de avond.", eyebrow: "Welkom tussen de poorten", title: "Jullie deur telt mee.", hero: true,
    paragraphs: (payload) => [`${greeting(payload)}de organisatie heeft je poort goedgekeurd. In Mijn huis vind je de actuele gegevens en voorbereiding voor de avond.`],
    action: { label: "Bekijk mijn poort", path: "/omgeving/huiseigenaar" }, footerReason: "Je ontvangt dit bericht na het goedkeuringsbesluit over jouw poort.",
  },
  portal_rejected: {
    kind: "host", subject: "Besluit over jouw poortaanmelding", preheader: "Bekijk de toelichting veilig in je huisomgeving.", eyebrow: "Beoordeling afgerond", title: "Er is een besluit over je aanmelding.",
    paragraphs: (payload) => [`${greeting(payload)}je poortaanmelding is voor deze editie niet goedgekeurd. Bekijk de toelichting in de beveiligde huisomgeving.`],
    action: { label: "Bekijk het besluit", path: "/omgeving/huiseigenaar" }, footerReason: "Je ontvangt dit bericht na het besluit over jouw poortaanmelding.",
  },
  contact_received: {
    kind: "confirmation", subject: "We hebben je bericht ontvangen", preheader: "De organisatie neemt contact op zodra dat kan.", eyebrow: "Bericht ontvangen", title: "Dank je wel voor je bericht.",
    paragraphs: () => ["Je bericht is veilig ontvangen. De organisatie neemt contact op zodra dat kan."],
    action: { label: "Bekijk de website", path: "/" }, footerReason: "Je ontvangt deze bevestiging omdat je het contactformulier hebt gebruikt.",
  },
  contact_notification: {
    kind: "admin", subject: "Er is een nieuw contactbericht", preheader: "Lees en beantwoord het bericht in de beheeromgeving.", eyebrow: "Nieuw in de inbox", title: "Een bezoeker heeft een vraag.",
    paragraphs: () => ["Er is een nieuw bericht via het openbare contactformulier. Behandel de inhoud in de beheeromgeving."],
    action: { label: "Open de inbox", path: "/admin" }, footerReason: "Je ontvangt dit bericht omdat je het organisatiecontact beheert.",
  },
  sponsor_received: {
    kind: "sponsor", subject: "Je voorstel is goed ontvangen", preheader: "We laten iets weten zodra het voorstel is bekeken.", eyebrow: "Samen voor de wijk", title: "Dank je wel voor je voorstel.",
    paragraphs: () => ["Je sponsorvoorstel is veilig ontvangen. De organisatie neemt contact op nadat het is bekeken."],
    action: { label: "Bekijk de website", path: "/" }, footerReason: "Je ontvangt deze bevestiging omdat je een sponsorvoorstel hebt ingestuurd.",
  },
  sponsor_notification: {
    kind: "sponsor", subject: "Er is een nieuw sponsorvoorstel", preheader: "Bekijk het voorstel in de beheeromgeving.", eyebrow: "Nieuw voorstel", title: "Een organisatie wil bijdragen.",
    paragraphs: (payload) => [`Er is een nieuw sponsorvoorstel${organization(payload) ? ` van ${organization(payload)}` : ""}. Beoordeel de gegevens in de beheeromgeving.`],
    action: { label: "Bekijk het voorstel", path: "/admin" }, footerReason: "Je ontvangt dit bericht omdat je sponsorvoorstellen beheert.",
  },
  group_ticket_message_organization: {
    kind: "admin", subject: "Nieuw bericht van een deelnemer", preheader: "Er wacht een reactie in Hulp & contact.", eyebrow: "Hulp & contact", title: "Een gesprek vraagt aandacht.",
    paragraphs: () => ["Er staat een nieuw bericht in Hulp & contact. Open de beveiligde beheeromgeving om de inhoud te lezen en te antwoorden."],
    action: { label: "Open Hulp & contact", path: "/admin" }, footerReason: "Je ontvangt dit bericht omdat je gesprekken voor de organisatie afhandelt.",
  },
  group_ticket_message_leader: {
    kind: "group", subject: "De organisatie heeft geantwoord", preheader: "Lees de reactie veilig in Hulp & contact.", eyebrow: "Hulp & contact", title: "Er staat een antwoord klaar.",
    paragraphs: () => ["De organisatie heeft gereageerd. Open Hulp & contact in de beveiligde deelnemersomgeving om het antwoord te lezen."],
    action: { label: "Lees het antwoord", path: "/omgeving/meeloper/groep" }, footerReason: "Je ontvangt dit bericht omdat de organisatie op jouw vraag heeft gereageerd.",
  },
  messenger_incoming_admin: {
    kind: "admin", subject: "Nieuw bericht in de cockpit", preheader: "Open de wachtrij of het gesprek.", eyebrow: "Cockpit · live contact", title: "Er komt een bericht binnen.",
    paragraphs: (payload) => [`Een ${senderRole(payload)} heeft een bericht gestuurd${reference(payload) ? ` in gesprek ${reference(payload)}` : ""}. Het gesprek staat ${queueStatus(payload)}. Bekijk en beantwoord de inhoud in de beveiligde cockpit.`],
    action: { label: "Open de chatwachtrij", path: "/admin" }, footerReason: "Je ontvangt dit bericht omdat je als beheerder inkomende gesprekken afhandelt.",
  },
  messenger_admin_reply: {
    kind: "group", subject: "Je hebt een antwoord van de organisatie", preheader: "Open je bericht in de persoonlijke omgeving.", eyebrow: "Hulp onderweg", title: "Er staat een antwoord klaar.",
    paragraphs: (payload) => [`${greeting(payload)}de organisatie heeft gereageerd op jouw bericht. Open het gesprek om het antwoord te lezen en te reageren. Je bericht blijft in jouw persoonlijke inbox staan.`],
    action: { label: "Open mijn berichten", path: "/omgeving" }, footerReason: "Je ontvangt deze e-mail omdat de organisatie jouw gesprek heeft beantwoord.",
  },
  participant_update: {
    kind: "generic", subject: "Bericht van de organisatie", preheader: "Een nieuw bericht van de organisatie.", eyebrow: "Bericht van de organisatie", title: "Er is een nieuwe update.",
    paragraphs: (payload) => [text(payload, ["message", "bericht"], "Open je persoonlijke omgeving voor de actuele informatie."), "De actuele situatie vind je in jouw persoonlijke omgeving."],
    action: { label: "Bekijk de update", path: "/omgeving" }, footerReason: "Je ontvangt dit bericht omdat de organisatie jou een gerichte update heeft gestuurd.",
  },
};

function text(payload: Payload, keys: string[], fallback = "") {
  for (const key of keys) {
    const value = payload[key];
    if (typeof value === "string" && value.trim()) return value.trim().slice(0, 6_000);
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
  }
  return fallback;
}

function firstName(payload: Payload) { return text(payload, ["firstName", "voornaam"]); }
function greeting(payload: Payload) { const name = firstName(payload); return name ? `Hoi ${name}, ` : ""; }
function groupName(payload: Payload) { return text(payload, ["groupName", "groepsnaam", "groupCode"], "jullie groep"); }
function headGroup(payload: Payload) { return text(payload, ["headGroup", "hoofdgroep", "groupName"], "de hoofdgroep"); }
function requestedStops(payload: Payload) { return text(payload, ["requestedStops", "gevraagde_stops"], "extra poorten"); }
function decision(payload: Payload) { return text(payload, ["decision", "besluit"], "beoordeeld"); }
function explanation(payload: Payload) { return text(payload, ["explanation", "toelichting"], "Bekijk de actuele afspraak in jullie omgeving."); }
function summary(payload: Payload) { return text(payload, ["summary", "samenvatting"], "Bekijk de actuele aanwijzing in de app."); }
function organization(payload: Payload) { return text(payload, ["organization", "organisatie", "contactName"]); }
function senderRole(payload: Payload) { return text(payload, ["senderRole", "afzender_rol", "senderLabel"], "deelnemer"); }
function queueStatus(payload: Payload) { return text(payload, ["queueStatus", "wachtrij_status"], "in de wachtrij"); }
function reference(payload: Payload) { return text(payload, ["reference", "registrationReference", "applicationReference", "ticketReference"]); }

function eventDateTime(value: unknown) {
  if (typeof value !== "string") return "";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "";
  return new Intl.DateTimeFormat("nl-NL", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Amsterdam" }).format(parsed);
}

function detailsFor(messageType: MailMessageType, payload: Payload): MailDetail[] {
  const entries: Array<[string, string]> = [];
  const add = (label: string, value: string) => { if (value) entries.push([label, value]); };
  if (messageType === "registration_received") {
    add("Inschrijfnummer", reference(payload));
    add("Aantal kinderen", text(payload, ["childCount"]));
  }
  if (["group_schedule_published", "group_schedule_corrected"].includes(messageType)) {
    add("Groep", groupName(payload) === "jullie groep" ? "" : groupName(payload));
    add("Startpunt", text(payload, ["startPoint", "startpunt"]));
    add("Adres startpunt", text(payload, ["startAddress", "startadres"]));
    add("Starttijd", eventDateTime(payload.startsAt) || text(payload, ["starttijd"]));
    add("Geen nieuwe gewone poorten vanaf", eventDateTime(payload.ordinaryStopAt) || text(payload, ["eindtijd"]));
  }
  if (["contact_notification", "sponsor_notification"].includes(messageType)) {
    add("Naam", text(payload, ["contactName"]));
    add("E-mail", text(payload, ["contactEmail"]));
    add("Onderwerp", text(payload, ["subject", "onderwerp"]));
    add("Bijdrage", text(payload, ["contributionType"]));
    const cents = payload.proposedAmountCents;
    if (typeof cents === "number" && Number.isInteger(cents) && cents >= 0) add("Voorgesteld bedrag", `€ ${(cents / 100).toFixed(2)}`);
    add("Bericht", text(payload, ["message"]));
  }
  if (["group_ticket_message_organization", "group_ticket_message_leader", "messenger_incoming_admin"].includes(messageType)) {
    add("Referentie", reference(payload));
  }
  if (messageType === "payment_link_ready") {
    add("Betaler", text(payload, ["payerName"]));
    const cents = payload.amountCents;
    if (typeof cents === "number" && Number.isSafeInteger(cents) && cents >= 0) {
      add("Totaal te betalen", new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100));
    }
    if (Array.isArray(payload.paymentParticipants)) {
      for (const participant of payload.paymentParticipants) {
        if (typeof participant === "string" && participant.trim()) add("Voor", participant.trim());
      }
    }
  }
  if (messageType === "payment_confirmed") add("Status", "Betaald");
  return entries.map(([label, value]) => ({ label, value }));
}

function actionPath(payload: Payload, defaultPath: string) {
  const candidate = text(payload, ["actionPath"], defaultPath);
  if (!/^\/(?!\/)[A-Za-z0-9/?=&._%~-]*$/.test(candidate)) return defaultPath;
  return candidate;
}

export function isMailMessageType(value: string): value is MailMessageType {
  return (MAIL_MESSAGE_TYPES as readonly string[]).includes(value);
}

export function contentForMessage(messageType: string, payload: Payload, brand: PremiumMailBrand): PremiumMailContent {
  if (!isMailMessageType(messageType)) throw new UnknownMailTemplateError(messageType);
  const definition = CATALOG[messageType];
  const details = detailsFor(messageType, payload);
  const dynamicTitle = messageType === "participant_update" ? text(payload, ["title", "titel"], definition.title) : definition.title;
  const dynamicSubject = messageType === "participant_update" ? text(payload, ["title", "titel"], definition.subject) : definition.subject;
  const codeValue = text(payload, ["code", "token"]);
  const paymentUrl = messageType === "payment_link_ready" ? validatedTikkieUrl(payload.externalUrl) : undefined;
  const action = paymentUrl ? { label: "Betaal via Tikkie", url: paymentUrl } : definition.action
    ? { label: definition.action.label, url: new URL(actionPath(payload, definition.action.path), brand.homeUrl).toString() }
    : undefined;
  const code = definition.kind === "otp"
    ? { value: codeValue, expiresText: text(payload, ["expiresText", "verlooptijd"], "De code verloopt over 10 minuten.") }
    : undefined;
  return {
    ...definition,
    title: dynamicTitle,
    subject: dynamicSubject,
    paragraphs: definition.paragraphs(payload),
    details: details.length ? details : undefined,
    primaryAction: action,
    code,
    reference: reference(payload) || undefined,
  };
}
