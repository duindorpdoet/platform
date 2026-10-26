# Live planbord, poortdeelname en wereldzegels

Basis: productie `78b7c4cee7566fd18d1858f17b9ec800910d3e3e`, gecontroleerd na fetch op 26 oktober 2026. De bestaande lokale werkboom is behouden. Deze uitbreiding staat op `codex/live-planboard-integration`, rechtstreeks vanaf de actuele productiebron. De andere uitbreiding op de stagingbranch wordt niet in productie meegenomen.

## Oorzaken en herstel

De bestaande poortenlijst bood pas een editor wanneer een operationele poort bestond. Een intake vóór OTP en een incomplete aanvraag konden daardoor niet worden hersteld; archieven ontbraken in de editorprojectie. Intrekken gebeurt nu op de concrete intake-/aanvraagidentiteit, met actuele impact, reden, versiecontrole, idempotentie en audit. Het maakt geen kunstmatige poort aan. Gearchiveerde poorten hebben een apart filter en een beperkte editor voor naam, contact en notities; heropening van deelname blijft een afzonderlijk organisatiebesluit.

De Poortenboekingang stuurde een ingelogde ouder zonder kindsessie door naar de kindcode. De ingang toont nu de bestaande bevoegde kindkeuze. `/poortenboek/ouder` blijft ook vanuit een geopend kindboek bereikbaar. De bestaande ouderautorisatie bepaalt de toegestane kinderen; de volwassen sessie blijft behouden. Het intrekken van een verkeerde poortaanmelding wijzigt geen gewone inschrijving, huishouden, betaling, kind of samenlooprelatie. Rolprojecties slaan ingetrokken, gearchiveerde en geschorste poorttoegang over.

Handmatige poortaanmaak zette geen instructie klaar. Bovendien vereiste goedkeuring een hoofdpoortwachter, terwijl een uitnodiging alleen ná goedkeuring kon worden aangenomen. Aanmaak met geldig contactadres maakt nu één instructie in de bestaande outbox. Alleen de persoonlijk geadresseerde, geverifieerde gebruiker kan een door deze organisatieflow gemaakte conceptuitnodiging aannemen. De bestaande eerste-teamlidregel kent dan hoofdpoortwachterschap toe; latere uitnodigingen blijven coadmin. Conceptlidmaatschap verleent nog geen operationele Poortkamerrechten. De gebruiker ziet een wachtstatus; de organisatie kan daarna goedkeuren en activeren. Contactgegevens alleen leveren geen lidmaatschap op.

## Planbord en domeinregels

Beheer → Poorten → Live planbord gebruikt private, duurzame route-intenties met stabiele bezoekidentiteiten. Bestaande startafspraken, publicaties, reserveringen, aankomsten en dispatch blijven de operationele bron. Een verzamelafspraak die niet als poortbezoek telt, staat als afzonderlijk startblok op het bord. De definitieve volgende bestemming gebruikt de geaccepteerde intentie zodra die veilig uitvoerbaar is; een blokkade geeft wachten/regie-informatie en geen stille vervanging.

De as gebruikt Europe/Amsterdam, standaard 16:30–21:30, en breidt uit voor bezoeken buiten dat bereik. Handmatige begintijden snappen naar tien minuten; bezoekduur en buffer behouden hun werkelijke waarde. Meeschuiven verplaatst uitsluitend latere geplande stops van dezelfde groep met dezelfde tijdsafstand. Werkelijke aankomst en afronding ontstaan uitsluitend door operationele registraties. Huidige en afgeronde stops en de finale zijn beschermd. Oude immutable legacyroutes blijven zichtbaar en beschermd; bewerken loopt via de bestaande bevoegde regie of een dynamische startplanning.

Serverpreview en opslag delen controles voor volledige openingsintervallen inclusief buffer, minimale poortduur, deelnemende status, locatie, dubbele poort, groeps-overlap, werkelijk berekende verplaatsing, groepscapaciteit, kinderen per groep, totale quota, huidige reserveringen, gepubliceerde ontvangsten, gewone stoptijd en finale. Exact aansluiten op een sluiting volgt het bestaande halfopen intervalcontract. Gewenste starttijden zijn motiveerbare voorkeuren; onveilige of onmogelijke intervallen zijn blokkades. De impacthash bindt ook alle relevante poortvensters, instellingen, publicaties en versies. Een verouderde bevestiging wordt geweigerd en nooit automatisch opnieuw toegepast.

De UI ondersteunt detailbewerking, toetsenbord, pointer/touch, annuleren met Escape, conflictenfilter tijdens slepen, zoom, schermvullend en scrollen. Private broadcasts en herstel-/focusverversing halen actuele snapshots op. Vertraagde antwoorden verdringen geen nieuwere antwoorden. Offline of mislukte verversing blijft zichtbaar.

## Publicatie en communicatie

| Actie | Actieve publicatie | Communicatie |
| --- | --- | --- |
| Preview / annuleren | Behouden | Geen |
| Conceptstart of vervolgroute wijzigen | Eerdere startpublicatie blijft geldig | Geen starttijdmail |
| Bevestigde afspraak als nieuw concept bewerken | Actuele impact en expliciete bevestiging vereist; oude publicatie blijft geldig | Geen tot publicatie |
| Startafspraak bevestigen en versturen | Bestaande gecombineerde bevestigings-/publicatietransactie | Eerste tijdmail of echte correctie per actuele ontvanger |
| Alleen poort-/routewijziging zonder andere gecommuniceerde starttijd | Nieuwe route-intentie / expliciete startpublicatie waar toepasselijk | Geen dubbele tijdmail |
| Concept ongedaan / opnieuw | Gecontroleerde herhaling van oorspronkelijke wijziging | Geen |
| Eerder gepubliceerde wijziging terugdraaien | Nieuw gecontroleerd concept, daarna expliciete publicatie | Passende communicatie bij nieuwe publicatie |
| Groep heropenen / afspraak intrekken | Bestaande intrekking | Intrekkingsbericht voor reeds gecommuniceerde afspraak; bestaand resetpad behouden |
| Handmatige poort aanmaken | Geen startpublicatie | Eén persoonlijke instructie bij geldig e-mailadres |
| Poort gewoon bewerken | Behouden | Geen nieuwe welkommail |
| Instructies opnieuw versturen | Behouden | Afzonderlijke gelogde, idempotente opdracht |

De bestaande worker blijft actuele ontvangersrechten, ingetrokken toegang, huidige publicatie, uitnodigingsverval en adresvrijgave controleren. Achterhaalde wachtende berichten worden onderdrukt; provideracceptatie en bezorgingshistorie blijven bewaard. Een outboxstatus is geen bewijs van mailboxontvangst. De gebruiker heeft voor deze release expliciet gevraagd de mailboxproef over te slaan; provider-/webhookcontroles en backup-/deploygates blijven van kracht.

## Wereldzegels en tutorials

De server bewaart een geversioneerd dekkingsbeleid voor de zes canonieke werelden. Goedgekeurde, actieve themapoorten met bruikbare beschikbaarheid tellen mee voor de hele avond, ook tijdens een tijdelijke pauze of vóór hun opening. Bij een werkelijke Anders-aankomst krijgen daadwerkelijk aanwezige kinderen een blijvend willekeurig nog ontbrekend wereldzegel. Dit staat los van fysieke bezoekzegels, hoofdstukken, finale en certificaat. Een laatste bruikbare Anders-stop kan meerdere resterende bonuszegels vereffenen. Herplanning, expliciet vertrek en afronding hebben een controleerbaar vereffeningsmoment op een bestaande eigen aankomst, vóór het vertrek vastligt. Geen aankomst betekent geen fictieve bonus; het planbord waarschuwt bij ontbrekende werelden zonder Anders-stop. Verdiende zegels blijven bij latere poorttoevoeging behouden.

De ouder-, poortteam- en kinduitleg verwijzen naar de echte schermen en benoemen het onderscheid tussen verwachting en registratie, ouder/kindkeuze en bonus-/bezoekzegels. De vaandelstap wijst nu naar het werkelijke vaandelonderdeel. Ankers gebruiken een zichtbaar passend element; een nog niet ingedeelde ouder krijgt het eigen groepsscherm als fasepassende terugval. De mobiele installatie-uitnodiging wacht tot de verplichte uitleg klaar is. De bestaande contracten blijven veertien volwassen stappen en negen kindstappen op versie 1; er zijn geen nieuwe stappen toegevoegd en voltooiingen worden niet gereset. Dagelijkse communitybevestiging blijft afzonderlijk per Amsterdamse kalenderdag; voortgang blijft per event, rol en kind geïsoleerd.

## Implementatie en verificatie

Acht additieve migraties `20261026024616` t/m `20261026044234` staan in de expliciete gereviewde releaselijst. Nieuwe tabellen blijven onder RLS in `app_private`, zonder clientgrants. Belangrijkste bestanden: `components/admin/live-planboard.tsx`, `lib/domain/live-planboard.ts`, de bestaande poortbeheerders/participantprojecties, de ouderingang, mailcatalogus/worker en Poortenboekprojectie. Nieuwe SQL-contracten staan in 080–088; `tests/e2e/live-planboard.spec.ts` gebruikt echte Auth, API, dispatch en uitsluitend synthetische lokale fixtures. [Desktop- en mobiele screenshots](screenshots/live-planboard/) tonen dezelfde geïntegreerde applicatie.

Lokale verificatie gebruikt uitsluitend Supabase-project `duindorp-planboard-20261026`, API 65321/DB 65322, met `MAIL_MODE=disabled`. Lint, typecheck, unit, productiebuild, clientartefactscan, volledige pgTAP-suite, SQL-lint/advisors en echte HTTPS-browserproeven worden uitgevoerd. CI behoudt de bestaande parallelle transacties, loadacceptatie, beveiligings- en tutorialsuites en voegt de planbordketen toe. De definitieve aantallen en releasebewijzen worden in de PR en de oplevering vastgelegd.

Uitgevoerd lokaal: 2.177 pgTAP-controles in 87 bestanden, 381 unittests in 56 bestanden, lint/typecheck/productiebuild/cliëntscan en zeven nieuwe echte HTTPS-planbordproeven geslaagd. SQL-lint geeft geen fouten; advisors melden alleen de bestaande `pg_net`-waarschuwing in `public`. De ouder-, kind- en poortteamproeven worden ook op mobiele en smalle schermen uitgevoerd, met daadwerkelijke ankercontrole, hervatten en herhalen/Escape. CI voert daarnaast de WebKit/iPhone-projecten uit; de lokale host mist de daarvoor vereiste systeembibliotheken.

## Release en herstel

De staginguitrol legde ook een bestaande datumfout bloot: dezelfde stagingmodus zette de inschrijfstart steeds op nu, terwijl de sluiting op 25 oktober bleef. De achtste migratie maakt heruitrollen van dezelfde modus idempotent, met behoud van bestaande datums, fase en kanaalkeuzes. Zij verlengt geen productiedeadline.

De branch doorloopt de bestaande stagingworkflow via `workflow_dispatch` met `runner_maintenance=none` en de expliciete `skip_mail_acceptance=true`. Bekende, al geïnstalleerde stagingmigraties worden alleen volgens de bestaande gepinde compatibilitylijst behouden. De versleutelde backup, geïsoleerde herstel-/migratieproef, behoudsfingerprints, preflight, build, provider-/webhookcontrole en deployment blijven vereist. Productie promoveert exact dezelfde succesvol geteste SHA met een eigen backup/herstelproef. Geen productie-reset, reseed of automatische correctie van onbekende echte accounts is onderdeel van deze uitrol.

Herstel verloopt via het bestaande runbook of een gereviewde voorwaartse reparatie. Verwijder geen duurzame route-intenties, commandoreceipts, publicaties of wereldtoekenningen om een oudere app te laten passen. Er zijn geen fysieke straat-/cameraproeven of mailboxontvangstproeven geclaimd.
