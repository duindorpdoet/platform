# Operationeel runbook

## Releasevolgorde

1. Laat CI groen worden op de te releasen commit.
2. Fast-forward exact die commit naar `staging`.
3. Controleer de GitHub deployment: migraties, Edge Function, Sites-release, Auth-config, Cron, security advisors, signed Event Webhook, OTP en transactionele testmail moeten groen zijn.
4. Controleer handmatig de staginghomepage, login en gesloten/allowlisted gedrag.
5. Fast-forward exact dezelfde SHA naar `production`. Een andere SHA wordt door de productionworkflow geweigerd.
6. Controleer `/api/health`: environment, revision en `registrationMode=closed`.

## Registratie veilig openen

Niet via een losse frontendvariabele. Eerst moeten echte operationele data, juridische versies en organisatiegoedkeuring aanwezig zijn. Pas daarna worden runtime `REGISTRATION_MODE=live` en een afzonderlijk geautoriseerd database-releasecommand samen gewijzigd. De huidige productionworkflow gebruikt de geautoriseerde instellingen `live` en `production_open`; de stagingworkflow gebruikt `staging_test`.

## Planning publiceren

1. Importeer bestanden eerst als dry-run en los alle rijmeldingen op.
2. Genereer een voorstel met vaste seed en controleer alle conflictcodes.
3. Laat een tweede bevoegde beheerder capaciteit, routevolgorde en vensters beoordelen.
4. Publiceer de geselecteerde planversies expliciet. Oudere versies en auditregels blijven bestaan.

### Startafspraken beoordelen na de gereedheidsreparatie van 29 oktober 2026

De software-release bevestigt geen echte groep en verstuurt geen deelnemersbericht. Een opgeslagen concept blijft leidend: alleen een expliciete beheeractie deelt de startafspraak. Het eerste adres blijft tot precies één uur voor de eigen start verborgen.

Open **Startregie** en controleer het opgeslagen startpunt en de starttijd. De tijdselect gebruikt nu één tijdnotatie, zodat bijvoorbeeld `+00:00` en `.000Z` dezelfde afspraak selecteren. Hiervoor zijn geen nieuwe indeling, gegevensreparatie of herberekening nodig. Lokale invoer blijft tijdens vernieuwen staan; bij een gewijzigde serverrevisie toont de kaart de opgeslagen afspraak en vraagt deze om beoordeling voordat de lokale keuze opnieuw wordt opgeslagen.

Open **Startafspraken bevestigen en versturen** om de concrete servercontrole te bekijken. Deze dialoog publiceert pas na de afzonderlijke bevestigingsknop. Bij een blokkade staat de echte reden met een actie naar **Kaders**, **Poorten**, **Startpunten** of de indeling. Ingevulde tijden betekenen niet dat beschikbaarheid is bevestigd. Controleer de werkelijke finalebeschikbaarheid en sla **Kaders → Laatste poort → Laatste poort veilig beschikbaar** alleen aan als dat klopt. De reeds opgeslagen tijden blijven behouden. Bij **Poorten** moet de finale goedgekeurd en actief zijn en operationeel **Gepland geopend** of **Open** staan; **Gesloten** en **Gepauzeerd** blijven blokkades. Controleer bovendien de echte poortopening, ingangspin en capaciteit. Verhoog geen capaciteit om een conflict te verbergen.

Niet-opgeslagen kaders zijn herkenbaar. **Kaders opslaan** leest de serverwaarden en gereedheid opnieuw terug. De publicatiecontrole gebruikt de opgeslagen revisie en toetst de startcapaciteit, één vertrek per startpoort per tien minuten, de finaleplaats, show plus wisseltijd en de harde gewone poortgrenzen. Gewenst einde blijft de afronding van de finale, bij voorkeur op of vóór de streeftijd, met maximaal dertig minuten groepsuitloop inclusief de hele show. Deze speling verhoogt de capaciteit niet.

**Poortvolgorde controleren** toont een verwachte route met een revisie. Het bezoekaantal is het aantal unieke gewone huizen plus de finale uit diezelfde routebron; een gekoppeld eerste huis telt eenmaal. Voor een nog niet berekende route staat **Aantal bezoeken volgt na routecontrole**. Een tijdschatting is geen aantal huizen. Tijdens de avond kunnen nog te lopen bestemmingen binnen de bestaande dynamische regels veranderen. Alleen een startafspraak publiceren zet de hele toekomstige poortvolgorde niet vast.

Een vrijgegeven bestemming toont het officiële adres, de bedoelde publieke ingangsinstructie en de opgeslagen effectieve ingangspin. Een handmatige ingangspin heeft voorrang. Zonder bruikbare pin blijven adres en instructie zichtbaar en verschijnt geen fictieve wijkpin. Toekomstige privébestemmingen blijven verborgen. Een wijziging van een al vrijgegeven ingang vereist eerst het oplossen van actieve bezoeken.

Het live planbord geeft bij een fout een Nederlandse melding en houdt de laatste succesvolle versie zichtbaar als mogelijk verouderd. Mutaties zijn dan geblokkeerd tot een actuele servercontrole slaagt. De eerste initialisatie gebeurt begrensd; wacht bij een melding dat er nog groepen worden voorbereid en vernieuw daarna. Alleen kijken naar het bord herverdeelt geen bestaande routes.

Ontbrekende themawerelden zijn een waarschuwing en blokkeren de indeling niet. Zolang huisinschrijvingen open zijn, is de dekking voorlopig. Bij werkelijk gesloten huisinschrijvingen wordt het compensatiebeleid vastgelegd. Bij een echte aankomst bij een gewoon huis met thema **Anders** krijgt ieder aanwezig kind willekeurig een nog ontbrekende wereldzegel. Die blijvend opgeslagen zegel is geen extra huisbezoek. Een late wijziging van het huizenaanbod wordt apart ter beoordeling aangeboden; bestaande zegels blijven behouden.

Herbereken alleen als een concrete controle meldt dat de route-invoer of revisie verouderd is, of als bewust een nieuwe verdeling nodig is. Gebruik dan **Groepen automatisch over startpunten verdelen**, beoordeel het voorstel en kies **Conceptslotverdeling opslaan**. Goede bestaande concepten worden niet eerst verwijderd. Beoordelen en vervolgens **Startafspraken bevestigen en versturen** blijven afzonderlijke expliciete beheerhandelingen.

De releasecontrole vergelijkt bestaande rijen en velden exact met de versleutelde backup. De vier nieuwe migraties zijn expliciet opgenomen in het ondertekende restorebewijs. Alleen de aantoonbaar afgeleide eerste werelddekkingspolicy per evenement, met de exacte bijbehorende auditregel voor een al gesloten huisinschrijving, mag worden toegevoegd. Bestaande policies, verdiende zegels, groepen, voorkeuren, concepten, publicaties, routes, instellingen en berichten blijven onder de oorspronkelijke bewaartoets vallen. Een herdeployment mag geen tweede initialisatie toevoegen. Bij een afwijking stopt de release; de productiepoort vereist daarnaast dezelfde succesvol op staging gedeployde SHA.

## Mail controleren

- OTP loopt via Supabase Send Email Hook en SendGrid.
- Applicatiemail loopt via `email_outbox`; Supabase Cron roept `/api/jobs/mail` iedere minuut aan.
- HTTP 202 betekent alleen provideracceptatie. `delivered`, `bounce`, `dropped` en `spamreport` komen via de signed Event Webhook.
- Controleer bij problemen eerst jobconfig/schedule, leases, retrytijd, providerstatus en webhooksignature; verstuur geen bulkherhaling.

## Incident tijdens de tocht

- Pauzeer een groep voordat een route- of rosterbesluit wordt genomen.
- Gebruik support override alleen met reden; iedere actie wordt geaudit.
- Een gesloten poort wordt gecontroleerd geskipt, nooit als fictief bezoek gemarkeerd.
- Offline clients mogen alleen eerder vrijgegeven data tonen; mutaties vereisen serverbevestiging.

## Retention

`api.retention_preview` is bewust preview-only. Controleer aantallen en datum met een eventbeheerder voordat ooit een afzonderlijke verwijdermigratie wordt ontworpen. Voor de oorspronkelijke operationele datasets blijft verwijdering een afzonderlijk besluit. De Poortkamer heeft expliciet automatische chatretentie: berichten, reacties en meldingen verdwijnen één kalendermaand na het evenement via `duindorp-poortkamer-maintenance`. Memberships en audits worden daardoor niet verwijderd. Zie [Poortkamer technisch rapport](../poortkamer/technical-report.md).
