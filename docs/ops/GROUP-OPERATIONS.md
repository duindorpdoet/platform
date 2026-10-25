# Samenhangende groeps- en startregie

Uitgangsbasis: `ff0997847b58742ab86fd2d1c46a9d37549a871c` op `origin/production`, na fetch gecontroleerd op 25 oktober 2026. Beide publieke health-endpoints rapporteerden die SHA. De read-only productie-inventaris van [run 40160590519](https://github.com/duindorpdoet/platform/actions/runs/40160590519) bevatte 83 migraties, laatste `20261025023205`. De succesvolle staginguitrol [40158013349](https://github.com/duindorpdoet/platform/actions/runs/40158013349) gebruikt dezelfde SHA; de `staging`-branch zelf bevat aanvullende diagnostiek en is dus niet zonder controle als productiebasis gebruikt. De oude lokale `main` en bestaande niet-gevolgde bestanden zijn behouden; implementatie staat in een afzonderlijke werkboom.

## Gedrag en contracten

- Het bestaande kanbanbord gebruikt de serverprojectie voor namen, actuele inschrijvingen/kinderen, voorkeur, betaalwaarschuwing, samenstelling en start. Groepskolommen klappen afzonderlijk in. Drag/drop en de mobiele verplaatskeuze blijven beschikbaar; verplaatsen, aanmaken en splitsingsherstel gebruiken nu dezelfde gecontroleerde commandogrens.
- `admin_group_operations_preview` geeft een actuele impact en fingerprint. `admin_group_operations_apply` voert één eventtransactie uit met autorisatie, locks, inputcontrole, inhoudsgebonden idempotentie, audit en outbox. Acties: reset, autofill, confirm, reopen, distribute, move, create, repair.
- Reset retireert groepen expliciet, supersedeert memberships en werkafspraken, beëindigt leiders/meekijkrechten en reserveringen en voegt een intrekking toe. Gepubliceerde routeplannen en startpublicaties blijven immutable. Een bestaande run blokkeert de hele reset. Actieve registraties behouden hun IDs; geannuleerde inschrijvingen worden niet hersteld. Registraties zonder actieve kinderen blijven zichtbaar als nog in te delen en worden niet tot een lege groep gemaakt.
- Autofill werkt zonder startslots, uitsluitend op de serverbevestigde partyrelaties. Blokken blijven intact. De deterministische voorkeur is de mode van oorspronkelijke registratiestemmen, bij gelijkspel minimale totale absolute afwijking, daarna vroegste tijd. Kinderaantallen veranderen het stemgewicht niet. Een te groot intact blok blijft zichtbaar als concept en vereist een bewuste aanpassing van het bestaande groepsbeleid voordat bevestiging mogelijk is.
- Ontbrekend target gebruikt 15, begrensd door het aparte evenementmaximum. Expliciete targets blijven behouden. Het instellingenformulier benoemt de standaard afzonderlijk van het maximum.
- Samenstelling bevestigen heeft een eigen fingerprint/revisie, actor, tijd en persoonlijke groepsmail voor actuele volwassen huishoudleden. Heropenen trekt een bestaande afspraak expliciet in. De slotplanner behoudt groep-ID's en leden; een bevestigde samenstelling beschermt de leden, een bevestigde/gepubliceerde start beschermt de afspraak.
- `admin_startregie_confirm_and_send` valideert de concrete start en publiceert met de mailintentie in één transactie. De deelnemer blijft de vorige publicatie zien tijdens conceptbewerking. De eigen locatie komt uitsluitend via de gedeelde publicatieprojectie vanaf T−60 beschikbaar.
- `start_time_communications` identificeert semantische tijdgebeurtenissen, los van interne revisies. De worker controleert actuele bevoegdheid, samenstelling en publicatie opnieuw. Alleen provideracceptatie/bezorgingsbewijs vormt een eerder gecommuniceerde tijd. De worker projecteert de werkelijk bekende oude tijd; een ongestuurde tussentijd wordt niet als een eerdere instructie beschreven. Een poortwijziging behoudt de wachtende eerste tijdmail. Tijdmails bevatten nooit een poortnaam/adres/coördinaten, ook na T−60.
- Financiële statussen, bedragen en betaalstromen blijven werkelijk; onbetaald blokkeert de operationele keten niet. De effectieve databasefuncties zijn doorzocht: de vier harde `PAYMENT_NOT_CONFIRMED`-guards zijn verwijderd. Er is geen actieve deadlinefunctie gevonden die uitsluitend wegens onbetaald registraties annuleert. Herinnerings- en deadlinekopij is aangepast. Er is geen automatische historische heractivering uitgevoerd.
- Onderhoudsconcepten bewaren onvolledige velden in een private tabel. Een onvolledige opening wordt geen operationeel venster. Bij een actieve poort kan beheer expliciet een onderhoudsconcept bewaren met behoud van de live status en marker. Activeren blijft een afzonderlijke volledigheidscontrole. Startpunt uitzetten toont impact en behoudt de gewone poort en eerdere publicatie; verwijderen beschermt finale, afspraken en actuele/pending ontvangst.
- De eigen Poortkamer leest bevestigde startgroepen uit dezelfde huidige immutable afspraak, gededupliceerd tegen reserveringen/bezoeken. Er worden geen kindnamen, betaalstatussen of volwassen mailadressen toegevoegd.
- De gedeelde halfopen intervalcontrole gebruikt distincte groepen en `max_concurrent_groups`. `max_children_per_visit` blijft per groep; de bestaande `max_children_total` blijft een aparte totale quota. Een scan verschuift de ontvangst naar de werkelijke aankomst en behoudt duur plus buffer. Dispatch benut de beschikbare resterende intervallen automatisch, onder dezelfde eventmutex; de huidige bestemming blijft staan.
- `group_portal_visits` legt de canonieke event/groep/poortidentiteit aanvullend vast. Bestaande echte bezoeken worden zonder historische IDs te wijzigen geïndexeerd. Legacy planstops worden via hun bestaande poortrelatie opgelost. Een aankomsttrigger voorkomt een tweede stopbezoek; aanwezige kinderen die buiten blijven krijgen nog steeds hun zegel. Onbereikte systeemskips tellen niet als bezoek. De private offline snapshotversie is verhoogd; de bestaande offline aankomstoutbox blijft behouden.

## Migraties en gegevensbehoud

Zes additieve migraties `20261025090000`–`20261025090500` zijn opgenomen in de expliciete releaselijst. Nieuwe tabellen blijven in `app_private`, met RLS en zonder clientgrants. De immutable historie wordt niet herschreven. Een compatibilitytabel behoudt oudere nog geldige startbevestigingen bij de overstap naar een fingerprint zonder betaling; bestaande bevestigingsrecords worden niet aangepast.

De lokale reset/concurrentieproef vergelijkt volledige fingerprints van kinderen, betalingsrecords, together-memberships en publicaties vóór/na reset. Het releaseproces blijft daarnaast de versleutelde backup/herstelproef, netwerkloze migratieproef en vergelijking van oorspronkelijke kolommen uitvoeren. Er is geen productie- of stagingreset, reseed, deelnemersmail of automatische gegevenscorrectie uitgevoerd.

## Uitvoerbare acceptatie

Gebruik een eigen Supabase-project/poorten; de ontwikkelproef gebruikte `duindorp-group-ops-20261025` op API 64321/DB 64322. `supabase db reset` is alleen toegestaan op die afgeschermde lokale fixtureomgeving. MAIL_MODE blijft disabled; een outboxrecord is geen bezorgingsbewijs.

```sh
pnpm lint
pnpm typecheck
pnpm test
pnpm exec supabase db reset --workdir /tmp/duindorp-group-ops-local
pnpm exec supabase test db --workdir /tmp/duindorp-group-ops-local
pnpm exec supabase db lint --local --schema api,app_private --level error --workdir /tmp/duindorp-group-ops-local
pnpm exec supabase db advisors --local --level warn --fail-on error --workdir /tmp/duindorp-group-ops-local
pnpm build
pnpm test:artifacts
```

De nieuwe contracten 076–079 behandelen reset/replay/stale input, onbetaald bevestigen, hashes zonder betaling, behoud van historie, autofill zonder slots, startmailsemantiek, T−60, fysieke intervallen en aparte capaciteitsbetekenissen, gedeeltelijk poortonderhoud, startpunt uitzetten, eigen ontvangstprojectie, autorisatie en de volledige weigering bij een lopende run. De bestaande scanproef 075 controleert nu ook fysieke bezetting na de scan, canonieke identiteit, onbetaalde deelname en de automatische keuze van een nieuw geschikt huis.

`scripts/acceptance/group-operations-concurrency.mjs` vereist een localhost-URL en een expliciet lokaal testcontainer. Deze proef gebruikt echte Auth-clients voor twee resetbeheerders en echte gelijktijdige PostgreSQL-dispatchtransacties voor het laatste ontvangstinterval. Daarna moeten fixtures opnieuw worden opgebouwd.

`tests/e2e/group-operations.spec.ts` doorloopt de volledige beheerflow en vergelijkt groep-ID's en leden vóór/na slotverdeling. De bestaande Startregie-, samenloop- en poortvolgordesuites zijn aangepast aan de expliciete gecombineerde bevestigingsactie. CI voert de nieuwe proeven met afzonderlijke fixtureherbouw uit.

## Release en herstel

1. Review de PR tegen de actuele productiebron; laat de volledige CI en bovenstaande integratieproeven slagen.
2. Gebruik het bestaande stagingproces met exacte SHA, backup-/herstelbewijs, migratielijst en cliëntscan. Geen bron uit de oude Sites-demo gebruiken.
3. Controleer op staging de resetimpact zonder een echte reset uit te voeren, de outboxstatussen en de eigen Poortkamer. Echte mail-/webhookproeven vereisen de bestaande geautoriseerde testontvangers. Provider accepted is geen mailboxbezorging.
4. Promoveer uitsluitend de exact geslaagde staging-SHA via de bestaande productionworkflow. Dit ontwikkelwerk verandert de productieconfiguratie niet.
5. Bij problemen: pauzeer de uitrol, behoud de database en outbox/audit. Geen downmigratie die publicaties, visitidentiteiten of commandoreceipts verwijdert. Gebruik de bestaande versleutelde herstelprocedure of een gereviewde voorwaartse reparatie. De oude app kent het nieuwe retired-lifecycle niet; een app-only rollback moet dat expliciet op compatibiliteit beoordelen.

Lokale validatie en schermafbeeldingen zijn ontwikkelbewijs. Fysieke straatproeven, cameras, echte SendGrid-bezorging en een uitrol van deze wijziging op staging/productie worden daarmee niet geclaimd.

## Uitgevoerde lokale resultaten

Op de definitieve migraties slagen **2.057 pgTAP-controles in 79 bestanden**, **372 unittests in 55 bestanden**, ESLint, TypeScript, de productiebuild en de cliëntartefactscan (1.041 bestanden). SQL-lint op `api` en `app_private` meldt geen fouten. De advisors melden uitsluitend de al bestaande waarschuwing over `pg_net` in `public`; deze uitbreiding verplaatst die bestaande extensie niet.

De echte reset-/dispatchconcurrentieproef slaagt. Verder slagen 25 relevante Chromium-browserproeven: acht voor het groepsbord en de volledige nieuwe keten, twaalf voor samenloopbeheer, vier voor Startregie en één mobiele beheer-/deelnemerroute. De echte keten wordt op desktop en 390 pixels gecontroleerd; voorbeelden staan in [de screenshotmap](screenshots/group-operations/).

Tijdens een tussentijdse browserstart ontbrak eenmaal de expliciete lokale containerkeuze. De daardoor aangemaakte 22 uitsluitend synthetische testhuishoudens met hun fixturekinderen/registraties/partijen zijn na een private herstelkopie transactioneel verwijderd; de bestaande immutable-trigger is binnen die transactie weer ingeschakeld. De juiste lokale container is daarna expliciet ingesteld en de twaalf samenloopproeven zijn opnieuw geslaagd. Er zijn geen productie- of staginggegevens geraakt.
