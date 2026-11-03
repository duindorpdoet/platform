# FrightNight 2027 serverkern

De nieuwe kern staat uitsluitend in `app_private.fn_*` met gecontroleerde functies in `api`. Zij gebruikt bestaande Auth-identiteiten en editiecapabilities. Nieuwe registraties vereisen expliciete instemming met `2027-test-v1`; versie, echte servertijd en actor worden bewaard. Zij krijgen een apart huishouden; synthetische seedgezinnen krijgen geen Auth-account, contactgegevens of historische household-koppeling. Geen nieuwe tabellen zijn aangesloten op oude betaaltriggers, routegroepen, mail-outbox, cron of pushworkers.

## Uitvoering en bevoegdheid

`frightnight_snapshot(slug)`, `frightnight_command(slug,command,payload,key)`, `frightnight_walk(slug,destination)` en `frightnight_admin_list(slug,resource,cursor,limit)` vereisen een echte actor. De server resolveert de editie, controleert actuele huishoudtoegang/capabilities en geeft alleen eigen of expliciet bevoegde DTO’s terug. Regielijsten zijn gepagineerd, maximaal 100 records. De command-ID is een UUID; een exacte replay geeft hetzelfde resultaat, gewijzigde inhoud onder dezelfde sleutel geeft conflict. Ook vóór replay wordt de huidige bevoegdheid opnieuw beoordeeld.

Service-only functies omvatten bootstrap, initialize, betaalorder/create/bind/confirm/reconciliatie/refund en gepubliceerde inhoud. `frightnight_initialize` vereist de exacte canonical stagingeditie, een expliciet bevoegde bestaande editiebeheerder en de bevestigde project/sitebinding. Initialisatie gebruikt een gedeelde private seedfunctie en vervalst geen sessie/JWT. Zij maakt alleen ownerloze synthetische fixtures; herhaling reset niets. De geautomatiseerde delegatie staat in de audit. Bootstrap/initialisatie worden pas na behoudsvergelijking en stagingbinding uitgevoerd.

## Transacties, capaciteit en klok

Korte commands en providerbevestigingen nemen dezelfde rijlock op de nieuwe editieconfiguratie. Dat serialiseert wijziging, route-uitgifte, samenloop, activiteiten, startplaatsen en refunds binnen een editie. Er vinden geen netwerk-, mail- of providerrequests onder die lock plaats. Het is een bewuste, eenvoudige schaalgrens; de lokale raceproef met twaalf gezinnen is geen productiebelastingbewijs.

Routekeuze filtert goedkeuring, effectieve opening/pauze, voorkeuren, hele groepsgrootte, persoonlijke historie, beschikbare capaciteit, gecontroleerde verbindingen en tijd voor bezoek plus terugkomst. Daarna tellen looptijd, drukstatus en reserveringsdruk mee. Eén partij heeft hoogstens één actuele bestemming. Een aankomstscan houdt de oude zone gedurende de opgegeven bezoekduur bezet terwijl de volgende bestemming wordt uitgegeven. Samenloop neemt de laagste intensiteit en de gezamenlijke comfortbeperkingen; eerdere beloningen blijven persoonlijk.

Een startblok is adviserend maar heeft een servercapaciteit in personen. Orders houden plaatsen vijftien minuten vast op echte tijd. Een late providerbetaling na heruitgifte blijft financieel `paid`, terwijl de inschrijving `draft` blijft met een duurzame omboek/refundmelding. Een passend ander startblok kiezen activeert de reeds betaalde plaatsen na dezelfde capaciteitscontrole; er ontstaat geen tweede betaling.

De afgeschermde editieklok bestuurt tochtvensters, zonepauzes, route- en bezoekleases. Auth, PSP-verificatie, orderholds, uitnodigingen en retentie gebruiken echte tijd. Routeclaims verdwijnen niet door alleen een snapshot of een timer. Hervatten beoordeelt een verlopen claim opnieuw; `admin.leases.recover` geeft maximaal honderd verlopen claims gecontroleerd vrij en vraagt expliciet hervatten. Een verstreken bewonerspauze heropent alleen binnen goedgekeurde openingstijden. Na het avondvenster resteert de passende Duinpadfinale.

## Koppelingen en gegevensbehoud

Betaalstatus volgt alleen de service/provideradapter, met bedrag-, valuta-, order-, editie- en testcontextcontrole. Betaald/refunded regresseren niet door late open/failed events. Ontvangsten en refunds hebben unieke ledgerregels. Refund en scan delen dezelfde lock en een terugbetaalde partij houdt geen actuele reservering.

`fn_mail_sink` heeft editie, stagingomgeving en afgedwongen sinkmodus, maar geen extern ontvangeradres en geen dispatcher. Retry verhoogt alleen een sinkteller. In-appmeldingen zijn afzonderlijke duurzame records. Push opt-in bewaart alleen de eigen editiegebonden subscription na expliciete toestemming; deze tabel heeft geen verzendworker. Sleutels en endpoints staan niet in snapshot of audit.

Huisfoto’s staan in een private bestaande-projectbucket met WebP/5MB-begrenzing. Storage RLS controleert editie, zone, actorfolder en eigendom/capability. Contactactivatie controleert de geverifieerde e-mailstatus van de echte eigenaar. Een bevestigde ligging binnen de Duindorp-regio blijft beoordelingsplichtig; organisatiegoedkeuring vereist contact- en locatiebevestiging bij niet-synthetische huizen. Een profielwijziging vraagt opnieuw beoordeling; een pauze/statusactie geeft geen toegang tot andere huizen.

Er zijn geen nieuwe automatische verwijder- of afsluitjobs. De standaardretentie van een testeditie is 365 dagen. Uitnodigingen vervallen na 24 echte uren. `test.reset` archiveert alleen synthetische scenario’s, trekt uitnodigingen/QR’s in en bewaart Auth, echte testerregistraties, financiële historie, audit en andere edities. Gebruik een nieuwe gekopieerde testeditie voor een volledig nieuwe tocht met dezelfde echte testaccounts. `test.cleanup` vereist een werkelijk verlopen retentie plus exacte slug/runbevestiging en sluit alleen die synthetische editie gecontroleerd af. Bestaande historische taken blijven behouden.

`test.walk.fixture` maakt herkenbare synthetische looptijdverbindingen voor tests. Deze zijn geen op straat geverifieerde wandelpaden. Kaartgeometrie moet uit gecontroleerde verbindingen of de begrensde serverprovider komen; ontbrekende geometrie blijft zichtbaar als ontbrekend.

## Herhaalbare verificatie

`supabase/tests/127_frightnight_2027_core.sql` draait in een transactie en rolt alle fixtures terug. De raceproef draait uitsluitend op een expliciet benoemde lokale Docker-verificatiedatabase:

```sh
python3 scripts/frightnight/db-concurrency.py --database frightnight_2027_acceptance
```

`local-fixture.py` is uitsluitend een lokale browserfixture, geen stagingseed of OTP-loginroute. Het maakt zes `.invalid`-persona’s, testbetalingen via het databasecontract, eigen bewonersaanmelding en beperkte financiële/activiteitrechten. Rapporten onder `validation/backend-*` bevatten hashes van de relevante bronbestanden. Zij bewijzen geen externe PSP, gepubliceerde stagingrelease, mobiele camera of piekbelasting.
