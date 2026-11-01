# Avond afsluiten en iedereen bedanken

Deze functie wordt pas actief na een bewuste organisatiebevestiging. De twee nieuwe migraties maken tabellen, functies, rechten en wrappers aan. Uitrollen, de beheerpagina bekijken en de modal openen sluiten geen evenement af en maken geen bedankcampagne of bedankjes. Er zijn geen nieuwe providers, geheimen, fysieke show-instellingen of herplanningen nodig.

## Bediening

Open bij het bedoelde evenement **Organisatie → Instellingen → Evenementinstellingen**. De kaart **Evenement afsluiten** verschijnt alleen met de daadwerkelijke evenementbevoegdheid `event_admin`; de API en database controleren die opnieuw.

1. Kies **Avond afsluiten…**. Controleer evenement, deelnemersaccounts, kinderen, deelnemende huizen, unieke beschikbare e-mailontvangers en ontbrekende contactadressen. Nog te activeren bestaande inschrijvingen staan apart vermeld.
2. Bewerk onderwerp en bericht in **Avond afsluiten en iedereen bedanken**. De standaardtekst is een vertrekpunt. Onderwerp: maximaal 200 tekens zonder regelafbrekingen; bericht: maximaal 20.000 tekens. De volledige definitieve inhoud, inclusief eigen alinea's en witruimte, wordt in app en mail gebruikt. Het blijft tekst; ingevoerde HTML wordt niet uitgevoerd.
3. Controleer de voorvertoning. **Annuleren** heeft geen gevolgen.
4. Kies alleen wanneer de avond werkelijk mag eindigen **Avond afsluiten en bedankbericht versturen**. De server legt één sluiting, vaste berichtversie, actor, tijdstip, doelgroep en duurzame verwerkingsopdracht atomair vast. Twee gelijktijdige organisatoren krijgen dezelfde bevestiging; de tweede tekst overschrijft de eerste niet.
5. Na succes staat **De avond is afgesloten. De bedankberichten worden verstuurd.** Datum en vastgelegd bericht blijven zichtbaar. Opnieuw afsluiten maakt geen tweede campagne. Bij een onbekende HTTP-uitkomst eerst **Actuele afsluitstatus controleren** gebruiken: de browser herhaalt de mutatie niet automatisch.

Een daadwerkelijk aangebroken evenement kan bewust worden afgesloten terwijl de administratieve fase nog `registration_open`, `registration_closed` of `planning` is. `ready`, `live`, `paused` en `completed` blijven eveneens ondersteund. Een toekomstige datum, `draft`, `archived` en een oefenevenement blijven geblokkeerd. De uitrol past die fase niet vooraf aan.

## Gevolgen en behouden historie

De centrale sluiting gaat voor persoonlijke groepsdeadlines. Nieuwe tochten, route-/finalescans en normale `finale.go`-aanvragen worden serverzijdig geweigerd. Lopende route-uitvoering krijgt zakelijk `stopped`, met reden `event_closed_by_organization`; een eerder beëindigde route wordt niet heropend. Een bestaande scantransactie en de sluiting delen een transactieslot, zodat hun volgorde vaststaat.

De sluiting voert geen QR1, QR2, Heks-, audio-, licht-, relay- of finalescan uit. De fysieke noodbediening wordt niet door de afsluitactie uitgevoerd of gewijzigd. Echte aankomsten, scans, scanrechten, oude deadlines, groepen, deelnemersaanwezigheid, fysieke zegels en historische mails blijven herkenbaar bewaard. Toekomstige generieke twee-uursbedankmails worden na de centrale sluiting niet opnieuw aangemaakt. Reeds geaccepteerde of onzekere verzendpogingen worden niet als onuitgevoerd behandeld.

De server bevriest de bestaande ingeschreven gezinnen, gekoppelde kinderen en deelnemende poorten. Goedkeuring en operationele deelname bepalen de poortenset: een inmiddels gesloten actieve poort telt mee; historische bezoek- of openingsbewijzen houden ook werkelijk deelnemende later gearchiveerde poorten herkenbaar. Concepten, expliciet met `portal_flags.fixture=true` gemarkeerde testpoorten en afgemelde poorten zonder deelnamebewijs worden niet toegevoegd. De echte geconfigureerde finalepoort wordt gebruikt. Latere configuratiewijzigingen veranderen deze set niet.

Alle gerechtigde kinderen krijgen in de weergave de bijbehorende zegels en het complete verhaal. `source=event_closure` onderscheidt cadeauzegels van fysieke bezoeken; een cadeau krijgt geen verzonnen scan of stop-ID. Fysieke bezoeken en bezoekersstatistieken worden niet opgehoogd. De volwassen Nachtpas en het Poortenboek gebruiken dezelfde bevroren set.

Bij een nog open evenement blijven de bestaande bereikte-poortrechten en historische reacties gelden. Na centrale sluiting zijn **Bedank alle huizen** en **Geef een huis een extra bedankje** onafhankelijke inzendingen per stabiel huishouden. Een algemene inzending omvat alle bevroren huizen; persoonlijk bedanken kan daarna nog per huis. Oude reacties blokkeren deze nieuwe typen niet. Een bewerking verandert het zichtbare bericht, maar stuurt geen nieuwe mail. De sluiting schrijft zelf geen bedankje namens een gezin.

## Terugblik, accountrechten en contacten

Gerechtigde accounts zien het vaste organisatiebericht bij de eerstvolgende appopening, login of gewone statusverversing. Overzicht en Route verwijzen naar de terugblik; Nachtpas en passende accountfuncties blijven bereikbaar. Gelezen-status wordt per account op de server opgeslagen. De terugblik blijft bereikbaar zonder verplicht bedankje of een steeds opnieuw verplichte modal.

Een account met meerdere kinderen ontvangt de campagne eenmaal. Accounts met verschillende adressen behouden hun eigen ontvangst; hetzelfde genormaliseerde adres heeft één campagne-mailopdracht. De appontvangst blijft per account bestaan. Ontbrekende of geblokkeerde contactadressen houden de sluiting niet tegen en worden niet als verzonden gepresenteerd.

Bestaande nog niet geactiveerde inschrijvingen en geldige uitnodigingsbindingen worden in de doelgroep vastgelegd. Na echte activatie krijgt dat account zijn eigen ontvangst en eerste campagne-mailopdracht eenmalig. Een willekeurig nieuw account of een later toegevoegde niet-vastgelegde gezinskoppeling krijgt hierdoor geen campagnebevoegdheid. Actuele intrekking van inschrijving, kinddeelname of toegang blijft leidend.

Ieder nieuw deelnemersbedankje heeft een duurzame ontvangst per doelhuis. Standaardbedankjes en reacties verschijnen uitsluitend als aantallen. Alleen aanvullende eigen tekst verschijnt als individueel bericht en kan een mailopdracht naar de actieve primaire poorteigenaar opleveren; actuele toegang wordt ook vlak vóór verzending gecontroleerd. Bewoners zien alleen hun eigen gekoppelde huizen in **Poortkamer → Bedankjes van deelnemers**, met nieuw/ongelezen voor eigen tekst, totaal en paginering. De afzender is **Een gezin uit Duindorp**; er worden geen nieuwe kindnamen, e-mailadressen of telefoonnummers gedeeld. De mail verwijst naar de bestaande geauthenticeerde Poortkamer en bevat geen login- of claimtoken. Zie [de aanvullende release en herstelregels](POORTKAMER-IMPACT-EN-BEDANKJES-20261101.md).

Een ontbrekend bewonerscontact verbergt de Poortkamerontvangst niet. Na herstel van de echte bewonerskoppeling controleert de worker zulke ontvangsten opnieuw in kleine batches, met minstens vijf minuten tussen contactcontroles. Het ontvangst-/adresregister voorkomt dubbele mailopdrachten.

## Worker, voortgang en herstel

De bestaande Cron-route `/api/jobs/mail` verwerkt per normale tick eenmaal de organisatiecampagne en eenmaal de huisbedankjes. `EVENT_EVENING_BATCH_SIZE` is standaard **10**, toegestaan **1–25**. Beide fan-outstappen lopen na elkaar. Daarna claimt de bestaande mailworker maximaal **10** outboxberichten en behandelt deze sequentieel. Er komt geen client-fan-out, snelle retrylus of verzending in het afsluitverzoek bij.

De beheerkaart onderscheidt **In wachtrij**, **Verwerkt**, **Provider geaccepteerd**, **Bezorging bevestigd**, **Mislukt**, **Uitkomst onbekend** en **Verzending geblokkeerd**. Deze tellers beschrijven verschillende stappen en hoeven geen optelsom te vormen. Provideracceptatie betekent geen bezorging; alleen de bestaande geverifieerde bezorgprojectie rechtvaardigt **Bezorging bevestigd**. Een opgeslagen huisbedankje blijft zichtbaar bij providerproblemen.

Gebruik op dezelfde beheerkaart **Alleen mislukte verzendjobs herstellen** voor de organisatiecampagne en de nieuwe bewonersbedankmails van dat evenement. Dit is een afzonderlijke bewuste beheeractie, met de bestaande rate-limit en auditregistratie. De actie selecteert uitsluitend:

- definitief mislukte outboxopdrachten zonder provideracceptatie of provider-ID en zonder begonnen gateway-envelop;
- definitief mislukte Resend-enveloppen zonder acceptatie of provider-ID, binnen het bestaande venster van 23 uur en 55 minuten.

Het herstel bewaart outbox-ID, ontvanger, bericht, provider en provider-idempotentiesleutel. Het gebruikt een vertraging van 30 seconden en herstelt geen opdracht vanaf acht pogingen. Een oude niet-herstelbare opdracht verdringt geen nieuw veilig herstelbare opdracht uit de begrensde selectie.

`accepted`, `delivered`, `unknown`, `reconcile` en verzending buiten het provider-idempotentievenster worden niet blind opnieuw verstuurd. Onderzoek daarvoor de bestaande mailregistratie en provider-/webhookbewijzen. Een geaccepteerde verzending wordt niet tot nieuwe verzending teruggezet; een onbekende uitkomst wordt niet als veilige mislukking behandeld. **Geen verzendjobs opnieuw klaargezet** betekent dat geen opdracht aan de veilige herstelcriteria voldeed. Het is geen bezorgbevestiging.

## Uitrol en gegevensbehoudend herstel

Volg de bestaande exacte-SHA-route uit [RUNBOOK](RUNBOOK.md): CI, staging met backup/herstelbewijs en behoudscontrole, daarna dezelfde SHA op productie. De migraties staan afzonderlijk in de release-allowlist:

- `20261101191738_event_evening_central_closure.sql`;
- `20261101191801_event_closure_house_thanks.sql`.

Leg vóór productie de daadwerkelijk geïnstalleerde gewijzigde functiedefinities, eigenaar, ACL, instellingen en signatures vast. De éénmalige catalogquery en de lijst van 30 bestaande functies staan in `outputs/event-evening-closure-20261101/capture-pre-release-functions.sql` en `pre-release-function-manifest.json` van de releasewerkboom. De query leest uitsluitend catalogi en maakt geen sluiting of mail. Bewaar de uitvoer bij het releasebewijs, samen met vorige app-SHA en de daadwerkelijk actieve Sites-release. De nieuwe interne herstelhelper en nieuwe featurefuncties hebben geen oude productiedefinitie; hun exacte versie volgt uit de migratie en release-SHA.

De vooraf vastgelegde productiebasis voor deze release is appcommit `7392e2f933b10418f7d33ce6442c69bfd71b6482`, de geslaagde [productieworkflow 41339747824](https://github.com/duindorpdoet/platform/actions/runs/41339747824) en GitHub-deployment `7477650446`. De concrete vorige immutable Sites-release is `/srv/sites/duindorphalloweenprod/releases/7392e2f933b1-41339747824-1`. Selecteer deze zo nodig via de bestaande Sites-interface; daarvoor is geen nieuw of verondersteld CLI-commando nodig.

**Voor de eerste bevestiging:** als er aantoonbaar nog geen centrale sluiting, nieuwe ontvangst of mailopdracht bestaat, kan de applicatie terug naar de vooraf vastgelegde vorige Sites-release. De nieuwe lege tabellen blijven staan. De aanvullende leesvelden en wrappers zijn verenigbaar met oude clients; er is geen downmigration of gegevensherstel uit een oude backup nodig. Controleer na rollback de daadwerkelijke revision en health.

**Na een bevestiging of nieuwe inzending:** behoud de centrale sluiting, bevroren doelgroep/poorten, accountontvangsten, gelezen-status, bedankjes, ontvangstregisters, outbox en provider-enveloppen. Gebruik een gerichte forward repair met de nieuwe mailtemplates en backendwrappers aanwezig. Een blinde app-/workerrollback naar een versie die `event_closure_thanks` of `house_thanks_received` niet kent, kan geldige nieuwe jobs als onbekend template laten mislukken. Een oud routesnapshot zonder centrale eindstatus is evenmin een herstelpad.

Als alleen een nieuwe UI-versie terug moet, houd een compatibele backend/mailworker actief die beide nieuwe typen kent en de centrale sluiting handhaaft. Gebruik de vooraf vastgelegde functiedefinities voor een beperkte beoordeelde herstelmigratie, met behoud van de sluitings-, autorisatie- en idempotentieguards. Oude functies integraal terugplaatsen na activatie kan routes of generieke mails opnieuw toelaten. Wis geen sessies, stemmen, voortgang, bedankjes of mailregisters; overschrijf geen nieuw ontstane gegevens met de oude volledige backup.

## Uitgevoerde lokale controles

Alle databasecontroles gebruikten een nieuwe geïsoleerde Docker-Postgres met `--network none` en uitgeschakelde Cron-uitvoering. De eerste lokale testcontainer liep na de succesvolle checks vol door tijdelijke databaseclones op zijn 1 GiB RAM-schijf; de uitsluitend synthetische teststack is daarna opnieuw opgebouwd met 4 GiB en een beperkt aantal clones. Dit was geen productie-incident. Alleen fictieve accounts en fixtures zijn gebruikt; geen productie-evenement is afgesloten en er zijn geen echte provider- of hardwareverzoeken uitgevoerd.

De eerste volledig schone feature-migratiecontrole gaf **142 gerichte SQL-asserties**: 84 voor centrale sluiting, doelgroep, cadeauzegels, toegang en herstel, plus 58 voor beide bedanktypen, Poortkamer, duurzame fan-out en gatewaygrenzen. Na aanvullingen voor ruwe tekstlengten en gezamenlijk herstel zijn beide migraties opnieuw volledig toegepast op een nieuwe lokale clone zonder featureobjecten: **170/170 asserties geslaagd** (101 in `125_event_central_closure.sql`, 69 in `126_event_house_thanks.sql`), inclusief expliciete uitsluiting van testpoorten, één momentopname voor uitnodigingsovergangen en dezelfde Unicode-/tekstlimieten als de app. De gerichte PL/pgSQL-controle van de nieuwe functies en gewijzigde wrappers gaf geen meldingen. Na de teruggerolde tests stonden sluitingen, campagneontvangers, nieuwe bedankjes, outbox en showpogingen allemaal op nul.

Twee onafhankelijke SQL-sessies bevestigden met verschillende teksten tegelijk: één sluiting, de eerste vaste inhoud en dezelfde bevestiging voor de tweede organisator. Deze checks zijn na de laatste migratiewijziging herhaald: de tweede aanvraag wachtte 1,868 seconde op de eerste transactie. In een afzonderlijke echte scan-/sluitingsrace wachtte de sluiting 1,918 seconde op een al lopende finalescan; een volgende gelijktijdige scan werd na sluiting geweigerd. Er ontstonden één echte finalescanontvangst, alleen de twee expliciete fysieke gezinsaankomsten en geen showtrigger.

De volledige bestaande SQL-suite is ook uitgevoerd: **127 bestanden, 3424 uitgevoerde asserties** in die run. **25 bestaande testbestanden** faalden in de huidige datum-/fixturecontext; alle 25 leverden exact dezelfde foutteksten en exitcodes in de lokale vergelijking met de bewaarde pre-featurefunctieversies. De afzonderlijke fixturefout in de nieuwe huisbedanktest is hersteld en gericht opnieuw geslaagd. De bestaande suite wordt daarom niet als volledig groen gerapporteerd.

Bewijs staat in `outputs/event-evening-closure-20261101/`: de laatste `event-close-ship-*` migratie- en SQL-resultaten, eerdere gerichte SQL-resultaten, `regression-summary.json`, `baseline-comparison.json`, `concurrent-close-report.json`, `scan-close-race-report.json` en het catalogmanifest. Dit is lokaal testbewijs; het bewijst geen productieprovideracceptatie of daadwerkelijke bezorging. De normale CI-, browser-, build- en releasechecks blijven afzonderlijk vereist.
