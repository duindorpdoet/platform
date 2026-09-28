# Premium portals — ontwerpsprint

De sprint maakt de bestaande omgevingen rustiger en consistenter. Messenger opent als gesprekkenlijst en vervolgens als volledig gesprek. De Poortkamer gebruikt echte chatballonnen, vaste schrijfbalk, live updates en rolgebonden moderatie. Kinderen vinden naamkeuze, vaandel, oefenpoort en eigen verschijning op afzonderlijke, herkenbare plekken.

## Wijzigingen

- Gedeelde ritmes voor tussenruimte, kaartpadding, compactere beheerknoppen, tabs, focus en mobiele schermranden.
- Eén zichtbare hoofdintro per beheerscherm; Messenger krijgt de beschikbare werkruimte.
- Poortenboekbeheer verdeeld in overzicht, namen/stemtijd en herkenbare kindteams.
- Poortkamer **Meer** verdeeld in zes gerichte onderdelen. Open/Pauze/Gestopt staan bij de Nachtwacht; andere schermen houden een compacte poortstatus.
- Uitleg voor deelnemers herschreven in gewone taal; kinderteksten in het Poortenboek aangepast.
- Home toont beide persoonlijke omgevingen, nieuws en vijf hoofdvragen. `/ontdek` geeft uitleg; `/faq` bevat zoeken en zes categorieën.
- Bestaande producttoegang blijft vindbaar. Persoonlijke gegevens blijven beschermd door account- en rolcontrole.

## Database en realtime

Forward-only migratie: `20260928010214_premium_portals_chat_moderation.sql`.

`portal_owners.chat_moderator` voegt expliciete moderatie toe zonder de operationele rol of het toegangsniveau te veranderen. De hoofdpoortwachter heeft eigen-teammoderatie; toewijzen/intrekken is vergrendeld, idempotent en geaudit. Mede-beheerders behouden hun bestaande pinrecht. De organisatie houdt de moderatie van communitykanalen.

Uitgebreide contracten:

- `portal_team_command`: nieuwe `chat_moderator`-actie; bestaande opdrachten worden gedelegeerd aan het bestaande contract.
- `portal_chat_snapshot`: `canPost`, `canPin`, `canModerate` en dezelfde begrensde geschiedenis.
- `portal_chat_action`: eigen-teammoderatie; communitymoderatie blijft aan organisatiebevoegdheden gebonden.
- `portal_room_snapshot`: moderatorstatus van leden en laatste vijf niet-verborgen organisatie-updates.
- `admin_portal_room_snapshot`: de huidige kanalen, actor en private communitytopic voor de organisatiechat.
- `poortenboek_admin`: herkenbare samenloop- of inschrijfreferentie bij kindteams.

Een gedeelde browserabonnementslaag voorkomt dat geneste schermen elkaar van hetzelfde Supabase-topic verwijderen. Berichten en moderatie versturen uitsluitend identifiers. Een wijziging aan een ouder geladen bericht wordt ook vernieuwd. Zichtbare schermen hebben daarnaast een verversingsinterval; bij terugkeer wordt de stand opnieuw opgehaald. Chatconcepten blijven alleen tijdelijk in het geheugen.

Er zijn geen nieuwe secrets, diensten of featureflags nodig. De bestaande productvlaggen voor Redactiekamer, Nachtpost en push staan aan in beide deploymentworkflows. De demonstratievlag blijft beperkt tot staging.

## Schermcontrole

| Omgeving | Gecontroleerde schermen |
| --- | --- |
| Publiek | Home, verhaal, werelden en alle zes wereldpagina's, kaart, meelopen, huisaanmelding, ontdek, nieuws, FAQ, sponsoren, contact, privacy, voorwaarden, toegankelijkheid en login |
| Ouder/deelnemer | Inschrijving, kinderen en betalen, samenloop, direct kind openen, Nu, Route, Groep, Nachtpas, Meer, profiel en communicatie |
| Meekijker | Beperkte groepsvoortgang, uitnodiging en toegang |
| Poortenboek | Login, welkom, Nu, Team/naam, vaandel, oefenpoort, Mijn boek, Ik/instellingen, verschijning, ouderbeheer en gedeeld toestel |
| Poortkamer | Nachtwacht, bezoeken, team/toegang, eigen chat, Poortplein, Omroeper, voorbereiding, presentatie, hulpvraag, oefenen, instellingen en terugblik |
| Nachtregie | Cockpit, imports, inschrijvingen, groepen, samenloop, Poortenboek, Messenger, updates, betalingen, poorten, planner, content/sponsors, beheerders, avondregie, simulatie en instellingen |
| Redactiekamer | Nieuws, voorvertoning, plaatsingen, Nachtpost, media, voorkeuren en afleverhistorie |

De lokale browsercontrole gebruikt desktop Chromium, mobiele Chromiumprofielen, smalle schermen vanaf 320px, tablet, WebKit voor iPhone, vergrote tekst, minder beweging, standalonepresentatie en offline/accountwisseltests. Er is geen fysiek Samsung Internet- of iPhone-toestel aangesloten; die hardware is niet afzonderlijk gevalideerd.

## Validatie

- `pnpm verify`: lint, types, 247 unit-tests, productiebuild en scan op clientbundels.
- Volledige lokale migratiereset en 55 pgTAP-bestanden / 1.422 checks, inclusief eigen-teammoderatie, toewijzing, intrekken, idempotentie, afscherming en cockpitupdates.
- Concurrencytests voor kindcodes/sessies, verkiezingen, poortrollen, uitnodigingen en exact één chatbericht bij gelijktijdige retries. Database-lint zonder fouten.
- Browserflows: 50 voor ingelogde portalen/beheer/samenloop, 48 publieke pagina- en headerchecks, 20 Poortkamerproeven, 16 Poortenboekproeven en 8 Redactiekamerproeven. Daarnaast 12 mobiele samenloopproeven. Allemaal geslaagd; nieuwe checks voor FAQ, live chat, moderatierechten, organisatie-updates en Messenger-terugnavigatie.
- Alle fixtures en mutations voor deze tests gebruiken de geïsoleerde lokale Supabase. Deployments gebruiken de bestaande staging- en productie-workflows.

Zie [het volledige featureoverzicht](features.md) voor de actuele productmogelijkheden.

## Beelden

Voorbeelden met fictieve lokale testgegevens:

- [Mobiele gesprekkenlijst](screenshots/premium/mobile-messenger.png)
- [Poortenboekbeheer](screenshots/premium/mobile-poortenboek-admin.png)
- [Mobiele groepsindeling](screenshots/premium/mobile-groepen.png)
- [Poortkamerchat](screenshots/poortkamer/room-samsung-chrome-berichten.png)
- [FAQ op desktop](screenshots/premium/desktop-faq.png)
- [Home op mobiel](screenshots/premium/mobile-home.png)
