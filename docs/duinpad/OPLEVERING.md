# Duinpad, Acteurskamer en finale-afsluiting

Geteste codecommit: `c6288a8781c7896303bed1bdeabf0b8f87ae52af`.

Gebouwd in de bestaande `duindorpdoet/platform`-app, in branch `codex/duinpad-actors-finale-20261031`. Basis: de op 31 oktober 2026 opnieuw bij GitHub geverifieerde actuele main/production `db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`. De oorspronkelijke werkmap op initialisatiecommit en de daar aanwezige gebruikersbestanden zijn behouden. Een aparte worktree voorkomt vermenging met andere herstelbranches. Geen package- of frameworkupgrade.

De aangeleverde zip heeft SHA256 `94f39f381d35c77c35cdf8589801152ca0f269800736b64c5d3a1f8fd5727a9d`; alle 29 manifestbestanden zijn gecontroleerd. De showbridgebaseline is ongewijzigd bewaard. De afzonderlijke reviewbare bridge-/relaypatch, versiecontract, toepassingscontrole en simulatiebewijzen staan in [bridge/README.md](bridge/README.md). Media, DMX-patch, showtiming, QLC- en audio-instellingen zijn daarin behouden.

## Werkelijke koppelingen en downloads

Alleen-lezen vastgesteld via de bestaande productieconfiguratie `event_route_settings.final_portal_id` en bijbehorende poort, dus niet afgeleid uit een poortnaam:

| Onderdeel | Werkelijke identiteit/status |
|---|---|
| Halloween-evenement | `0e48b75c-ae67-4934-8898-409dd127c871` |
| QR2, bestaande finale | `4fa3fc24-1510-4a0c-86e0-e5595c6b7522`, weergave P-38, “De laatste Poort!” |
| QR2-credential | Een geldige, niet ingetrokken credential bestaat. Productietokens/hashes zijn niet opgehaald. |
| QR1 vóór de heks | Geen expliciete bestaande koppeling aangetroffen. De fysieke ingang moet de organisatie aanwijzen. Geen P-02, P-12 of Heksendisco gegokt. |

Beheer: `/admin?view=duinpad`, bereikbaar voor bevoegde organisatie/poortbeheerders; tevens gelinkt vanuit de bestaande Poortkamercontext. Twee afzonderlijke kaarten tonen de code, locatie, korte code en preview. “Nieuw los showcheckpoint” maakt uitsluitend een QR1-showcheckpoint, geen gewone routestop of planning. Bestaande geschikte poortcredentials kunnen worden gekoppeld. QR2 blijft altijd de finale uit de bestaande evenementconfiguratie.

Na normale geautoriseerde uitrol zijn de echte downloadroutes:

- `/api/duinpad/poster?stage=qr1&format=pdf&mode=mono`
- `/api/duinpad/poster?stage=qr2&format=pdf&mode=mono`

`mode=colour` levert kleur. De printknop gebruikt dezelfde geauthenticeerde PDF via een tijdelijke browserblob. QR1 geeft bij ontbrekende configuratie “Nog niet ingesteld”. Er wordt geen demo-QR afgedrukt. Bestaande QR2-postercredentials blijven geldig; downloaden roteert niet. Standalone QR1-rotatie is afzonderlijk geautoriseerd en expliciet bevestigd; gekoppelde poortrotatie blijft in de bestaande Poortkamer. Een geldige appcode en een verbonden showcomputer worden afzonderlijk getoond. Deze nieuwe routes zijn niet als live gedeployd voorgesteld.

## Identiteiten en transacties

De technische relaygroep is de bestaande **run-UUID**, bij QR1, QR2, statusherstel en acteur `finale.go` gelijk. Er zijn geen nieuwe G-/SL-identiteiten of deelnemersaccounts gemaakt. De UUID voldoet aan de bestaande relaylimiet van 40 tekens.

Een zakelijke scan gebruikt de actieve stabiele together-party, anders het geauthenticeerde account. Account-/partijclaims, actuele en historische samenlooplidmaatschappen en bewaarde deelnemers verhinderen dat uittreden, herindelen, een tweede tab of een ander apparaat het scanrecht vernieuwt. Zonder samenloop hebben twee gerechtigde volwassen accounts ieder hun eigen account-unit; een household vervangt geen account- of party-identiteit.

De eerste geaccepteerde finale-aankomst bewaart onder databasevergrendeling de echte finalestop, eerste servertijd en exact `+ interval '2 hours'`. Dezelfde transactie bevriest het cohort: gerechtigde volwassen accounts van actieve, aanwezige runkinderen en hun geaccepteerde huishoudleden. Eerder vrijwillig vertrokken deelnemers worden niet opnieuw actief. Latere herindelingen verschuiven de deadline niet. Ook cohortleden zonder eigen scan delen de eindtijd.

Finale-aankomsten blijven twee stappen: credential controleren, daarna expliciet aanwezigheid/keuzes bevestigen. Ieder aanwezig kind krijgt een echte aankomstzegel, ook bij overslaan. Alleen de beperkte eigen account/partijscope is via de nieuwe finale-RPC toegestaan; gewone routehandelingen blijven groepsleider-only. De fysieke route en poortbezetting worden direct afgerond. Overige gerechtigde accounts kunnen daarna de bewaarde finalestop gebruiken. Historisch routeherstel verwerkt uitsluitend zakelijke aankomsten; SQL roept nooit de relay aan.

De bestaande routeworker verwerkt verstreken avonden idempotent. `evening_ends_at` is de logische deadline; `processed_at` registreert de verwerking. Snapshots weigeren al op de servergrens nieuwe starts, ook vóór de volgende workerpoll. Overzicht en Route tonen daarna de warme afsluiting en bestaande `FamilyPortalThanks`; Groep, Nachtpas en accountinstellingen blijven bereikbaar. Bedankrechten blijven gebaseerd op eigen bewezen aankomsten, niet op alleen de deadline.

## Showstart en herstel

Zakelijke scan, fysieke poging en avonddeadline hebben afzonderlijke records. Een gedeeld groepsslot omvat QR2 en handmatige `finale.go`, onafhankelijk van het account. Herhaald QR1-aanmelden gebruikt een bevestigde registratie; herhaald finale bevestigen start geen nieuwe voorstelling.

De app legt de exacte payload/hash en poging vast vóór de directe HTTP-aanroep. De serveraanvangstijd van de bewuste handeling blijft de korte intentiegrens; een trage zakelijke transactie mint geen verse oude showintentie. De relay-POST heeft maximaal 15 seconden wachttijd en geen automatische retry. Er is geen uitgestelde SHOW-outbox. Annulering/timeout na mogelijke dispatch blijft unknown. Alleen `2xx && ok===true` bevestigt de betekenis van de stage; QR2 komt pas na beide lokale start-ACKs terug als gestart. Een software-ACK bewijst geen hoorbaarheid/zichtbaarheid ter plaatse of showvoltooiing.

- Expliciet blocked: lokale reden tonen; een nieuwe bewuste handeling kan later opnieuw aanvragen.
- 503/offline: niets voor later bewaren; begeleider inschakelen.
- Unknown/interrupted/recovery_required: geen nieuw event-ID of replay; eerst de bestaande ontvangst alleen-lezen controleren.
- Herstelpad app: `GET /api/duinpad/receipt`; geautoriseerde eigen poging, oorspronkelijke payloadhash en groep worden gecontroleerd via `GET /api/integration/receipts/<id>`. Een ontbrekende receipt is geen bewijs van niet uitgevoerd.
- Het lokale regieherstel voor ondubbelzinnig niet uitgevoerde finales staat in de bridgehandleiding. Een bewezen start kan niet door `reset_groups` een tweede appgestuurde finale krijgen.

Heks GO blijft een bewuste lokale/bevoegde acteursdruk. QR1 start geen licht, audio, tijdlijn of avondklok. De bestaande voorbereiding blijft intact. Alleen de lokale controller geeft na beide finale-ACKs de volgende Heks GO vrij; geen extra vrijgave-QR/API.

## Acteurs en mail

Organisatiebeheer: `/admin?view=actors`. Acteurskamer: `/omgeving/acteur`. Claim: `/uitnodiging/acteur`. Nieuwe serverrechten komen uitsluitend uit actuele actieve databasekoppelingen; login alleen, user_metadata of oude JWTs geven geen bediening. OTP/Google, callback, veilige terugkeer en omgevingkiezer blijven de bestaande voorzieningen. De uitnodiging activeert alleen na expliciete bevestiging met het juiste servergeverifieerde e-mailadres. Rechten beginnen leeg; stop-all wordt apart toegewezen. Er ontstaan geen deelnemersinschrijvingen, kinderen of betalingen.

Het geversioneerde v1-actorprotocol is aan app, relay én bridge geïmplementeerd. Alleen allowlisted acties, exact begrensde rollen/zones, korte HMAC-grants, actuele revisions, gefilterde status en bijpassende receipts worden geaccepteerd. De actorstatus toont geen globale regiegroepen, DMX, audio-instellingen of andere acteursrechten. Zie ook [ACTEURSKAMER.md](ACTEURSKAMER.md) en de bridgehandleiding voor het begrensde revocatievenster en lokale herstelprocedure.

Mailtypen `actor_invitation` en `duinpad_evening_thanks` gebruiken de bestaande premiumcatalogus, duurzame gateway en suppressies. Eén bedankmail per gerechtigd deelnemend volwassen account met unieke event/account-dedupe, na de vaste deadline. Samenloop deelt het scanrecht en niet automatisch één mailadres. De bedanklink vereist de eigen login en bevat geen claimtoken of gezinsdata. Een uitnodigingstoken staat uitsluitend in de claimlink bij verzending, niet als plaintext in de uitnodigingstabel/outbox. Queued/provider accepted/delivered/unknown/failure houden de bestaande betekenis; er is geen echte bezorging geclaimd.

## Uitrol en bediening

De drie nieuwe migraties zijn additief en seedloos:

1. `20261031143846_duinpad_actor_access.sql`
2. `20261031143910_duinpad_finale_evening.sql`
3. `20261031143920_duinpad_checkpoints_and_show_attempts.sql`

De bestaande gecontroleerde release-migratielijst en staging/productie-runtimeomgeving zijn uitgebreid. Backup, geïsoleerde restore, behoudsvergelijking, exacte succesvolle staging-SHA en productiechecks blijven verplicht. Geen wijziging aan migratiehistorie, routeplanning, openingstijden, registratiegegevens of sleutels.

Backend-only configuratie, zonder waarden:

- `DUINPAD_SHOW_API_BASE_URL`: echte HTTPS-relayorigin, zonder pad.
- `DUINPAD_SHOW_API_TOKEN`: bestaande relay `DUINPAD_RELAY_SECRET`.
- `DUINPAD_EVENT_SCOPE_ID`: bestaande UUID van het evenement; apart per omgeving.
- `DUINPAD_ACTOR_AUTH_SECRET`: afzonderlijk gedeeld app/relay/bridgegeheim.
- `DUINPAD_ACTOR_INVITE_SECRET`: afzonderlijk app-only uitnodigingsgeheim.

De deploymentworkflows gebruiken environment-secrets voor de origin en geheimen en een environment-variable voor de event-UUID. Ontbrekende optionele showconfiguratie blokkeert die verbinding; bestaande appfuncties blijven bruikbaar. Controleer vóór activatie de kloksynchronisatie op VPS/relay/showcomputer, compatibiliteit, concrete QR1-locatie en gekozen bediening. Kies samen met regie internetbediening of bewuste lokale reservebediening; geen ongecoördineerde dubbele bediening. Rook blijft standaard uit.

Bij problemen: schakel de internetkoppeling uit via normale configuratie/release, bewaar scan/deadline/receipt/mailhistorie, en gebruik na expliciete regieafspraak de lokale reserve. Een rollback gebruikt geen destructieve downmigratie. Herstel zakelijke fouten met een gerichte vervolgmigratie.

In deze sessie zijn **geen** productie-migraties, deployment/herstart, echte uitnodigingen/mails, Google-loginproeven of hardwaretriggers uitgevoerd. De publicatie vereist de bestaande releaseprocedure en expliciete sessievrijgave; het overdrachtspakket vormt daarvan geen bewijs. Alle software-/simulatiebewijzen en de resterende beperkingen staan in [TESTRESULTATEN.md](TESTRESULTATEN.md) en [OPEN-PUNTEN.json](OPEN-PUNTEN.json).
