# Danny's testhandleiding — FrightNight 2027

Gebruik uitsluitend **https://staging-halloween.duindorpdoet.nl**. De canonieke testeditie is `frightnight-2027-test`, datum **30 oktober 2027**, tijdzone **Europe/Amsterdam**. De gepubliceerde SHA, laatste release en werkelijk uitgevoerde proeven staan in [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md) en [ACCEPTANCE-MATRIX.md](ACCEPTANCE-MATRIX.md). Een lokale groene test bewijst geen geslaagde stagingrelease.

## Inloggen en rollen

Open `/inloggen`, vul je eigen toegestane testadres in en vraag zelf een code aan. Gebruik die code in dezelfde browser. Je bestaande account blijft bestaan; er is geen gedeeld wachtwoord en geen keuzemenu waarmee je jezelf beheerder maakt. De automatisering vraagt geen OTP aan. Een nieuwe menselijke tester moet eerst bewust worden toegestaan binnen de bestaande stagingmail-/authpolicy; stuur geen uitnodigingscampagne naar oude deelnemers.

| Testrol | Ingang | Toegang en voorbereiding |
|---|---|---|
| Danny, organisatie/testbeheer | `/avondregie` en `/testcentrum` | De releasebootstrap koppelt uitsluitend het geverifieerde bestaande Danny Goldenbelt-account als `event_admin` aan de nieuwe editie. Dit verleent geen nieuwe productie- of 2026-rechten. |
| Gezin A en gezin B | `/nachtpas` op twee zelfstandige accounts | Ieder vraagt zelf OTP aan, schrijft een eigen gezelschap in en heeft een eigen serverorder. Gebruik twee browsers/apparaten; twee tabs van één account zijn één gezin. |
| Bewoner A en B | `/mijn-zone` | Ieder meldt zelf een huis aan, bevestigt contact en ligging en wacht op beoordeling. Iemand krijgt daardoor geen toegang tot andere huizen. |
| Financieel beheer | `/avondregie`, betalingen | Alleen een expliciet aan deze editie toegekende `payments_manage`-capability; geen globale admin. |
| Activiteitmedewerker | `/avondregie`, boekingen | Een eventbeheerder wijst de medewerker aan een concrete activiteit toe. Alleen bijbehorende boekingen zijn bereikbaar. |
| Hulppunt | `/avondregie`, meldingen | Alleen expliciete `live_support`-toegang binnen deze editie. |

De overige menselijke testaccounts zijn geen vooraf verzonnen accounts. Open als hoofdbeheerder **Avondregie → toegang → Bevestigde contactpersoon toegang geven**. Vul het door de tester zelf bevestigde adres in, kies alleen de benodigde bevoegdheden, geef een reden en bevestig account en editie. Bestaande rechten open je via **Bevoegdheden bekijken** en bewaar je met **Bevoegdheden opslaan**. Ze worden met een verwachte actuele versie opgeslagen; bij een gelijktijdige wijziging vernieuw je eerst. De laatste hoofdbeheerder kan niet worden verwijderd. Voor een zuivere activiteitmedewerker kies je een nieuw bevestigd adres met een lege rechtenlijst en **Bevestigd account opzoeken zonder bevoegdheden**. Het serverantwoord toont het account-ID zonder eerst een bredere rol toe te kennen. Vul dat ID en de activiteit in bij **Een medewerker, één activiteit**, zet de toegang aan of uit en kies **Activiteitentoegang bewaren**.

De tijdelijke `.invalid`-identiteiten van geautomatiseerde acceptatie zijn geen inlogaccounts voor Danny: sessies worden beëindigd, rechten ingetrokken en accounts geblokkeerd, terwijl Auth-historie behouden blijft. Het acceptatierapport bevat geen wachtwoorden of sessies.

## Een schone proef voorbereiden

1. Controleer `/api/health`: staging, juiste SHA, `eventSlug=frightnight-2027-test`, `brand=frightnight-2027-v7` en de zichtbare betaalprovider. Controleer in het testcentrum editiecode, run, seedversie en bewaareinddatum.
2. Gebruik voor een onafhankelijke proef **Een eigen testeditie → Configuratie kopiëren**, bijvoorbeeld `frightnight-2027-test-januari`. De kopie bevat instellingen en spellen; geen personen, orders of historische rechten. Open de kopie via de gecontroleerde editieknop. De server bewaart de keuze actor- en sessiegebonden.
3. Kies **Scenario veilig aanmaken**. Eén testronde kan niet dubbel worden gevuld; herhaling vraagt eerst een expliciete reset. De basis bevat ownerloze synthetische gezinnen, zones, activiteiten en echte QR-tokens, zonder oude huishoudens of Auth-accounts te hergebruiken.
4. Kies desgewenst **Synthetische wandelgraaf voor routeproeven**. Deze geeft reproduceerbare rekentijden; hij is geen goedgekeurde straatnavigatie. Echte huizen vereisen bevestigde ligging en organisatiecontrole van werkelijke wandelverbindingen voordat een straatproef slaagt.
5. Zet de editieklok op `2027-10-30 17:05` voor de Lantaarnentocht, of `18:40` voor de Worteltocht. De eerste duurt 17:00–18:30, maximaal twee pompoenen; de tweede 18:30–21:00, zelf kiezen tot vijf. Een startblok spreidt aankomst. Het begin van het gekozen avondvenster blijft geldig.
6. Download vooraf het noodpakket, startbord en benodigde zoneborden. Bewaar ze op beide testtoestellen en druk operationele instructies af.

Een nieuw gezin in je kopie laten beginnen: open eerst zelf de juiste kopie en kies **Een ander gezin laten testen → Maak een testuitnodigingslink → Link kopiëren**. Deel die link zelf met de toegestane tester. Er wordt geen e-mail verzonden. De ontvanger vraagt zo nodig zelf een inlogcode aan, vinkt instemming aan en kiest **Open deze testeditie**. Daarna begint hij met een eigen lege inschrijving in deze kopie. De ondertekende link is acht uur geldig, geeft geen beheerdersrol en opent geen gegevens van andere gezinnen. Het token staat in een URL-fragment en wordt na inlezen uit de adresbalk gehaald; deel geen screenshots van uitnodigingen.

Zonder geldige uitnodiging vereist wisselen naar een kopie al aantoonbare deelname, een eigen huis of een rol. De editiecode kennen geeft geen toegang. Als de identiteit of editie wijzigt, worden privébrowsergegevens gescheiden en bij uitloggen gewist. Oude privépagina's worden ook bij terugnavigeren eerst verborgen en opnieuw gevalideerd.

## Een volledige gezinsreis testen

Schrijf gezin A en gezin B ieder zelfstandig in via de Nachtpas. De server berekent plaatsen en prijs in eurocenten. Open testcheckout. Bij `contract` is duidelijk zichtbaar dat geen externe betaling plaatsvindt; kies in het testcentrum de betreffende inschrijving en speel de providerstatus na. Alleen de serverbevestiging maakt de registratie betaald. Een return-URL of succesknop doet dat niet. Test ook mislukt, geannuleerd, verlopen, dubbele en vertraagde bevestiging.

Scan het startbord met de camera of gebruik de handmatige code. De server geeft één bestemming. Een geldige scan daar rondt dat bezoek eenmaal af; dezelfde scan mag geen tweede beloning opleveren. Test pauzeren/hervatten, overslaan, lagere intensiteit, rook-/flits-/stepvrijvoorkeuren en gelijktijdige scans. Een verlopen lease vraagt om hervatten en nieuwe beoordeling. Stoppen leidt naar de passende Duinpadfinale; alle huizen of spellen voltooien is geen voorwaarde.

Nodig het andere betaalde gezin uit voor samenloop. Laat de andere contactpersoon zelf instemmen. Vergelijk beide actuele bestemmingen en voortgang. De gezamenlijke omvang, laagste spanning en strengste comfortvoorkeuren gelden. Laat iemand onderweg verlaten en scan op beide accounts. Een tweede volwassene toegang tot **dezelfde inschrijving** geven is een aparte functie en creëert geen tweede betaling.

Boek en annuleer een activiteit, speel de drie raadsels en drie pleinspellen, bezoek Duinpad, doorloop de digitale finale en download de eigen Nachtpas. Lichtvonken, zegels, meldingen, bedankjes en hulpantwoorden zijn duurzame serverrecords. Push blijft opt-in en is niet nodig voor de tocht. In staging wordt externe pushbezorging niet door de nieuwe editie geactiveerd.

## Bewoner en avondregie

Een bewoner meldt zijn eigen zone aan, bevestigt accountcontact en adres/ingang, voegt een foto toe en dient de zone in. Een Snoepzone heeft geen schrikniveau; een Frightzone heeft één tot vijf pompoenen. Wijzigingen die beoordeling vereisen sluiten de zone totdat de organisatie haar goedkeurt. Foto's worden begrensd, opnieuw gecodeerd en privé opgeslagen. Druk het echte zonebord af; scan het vanaf een ander apparaat.

Bekijk in **Avondregie → mail → Testmail bekijken** de werkelijk opgeslagen betaalcapture. Het voorbeeld heeft dezelfde FrightNight-stijl, Pompoenkoning, serverbedrag en orderreferentie en is via de browser afdrukbaar. Het is zichtbaar gemarkeerd als niet verzonden. Alleen betaaldienst-/eventbeheer van deze editie kan het openen; een voorbeeld bekijken of opnieuw proberen verzendt geen e-mail.

De regie beoordeelt huizen, bekijkt drukte/reserveringen, beheert startblokken, activiteiten en inhoud, beantwoordt hulpvragen, publiceert in-appberichten, bekijkt betalingen en logboek en maakt begrensde exports. Gebruik bij zones **Wandelverbinding vooraf bekijken**: controleer de werkelijke lijn, minuten en bron en toets de openbare veilige paden ter plaatse. Bevestig met reden via **Gecontroleerde wandelverbinding bewaren**. Beoordeel de terugverbinding naar Duinpad afzonderlijk; een providerlijn of synthetische graaf is geen fysieke goedkeuring. Een globaal gepauzeerde editie kan niet verder scannen. **Verplichte QR-scans opheffen** vervangt de scan door een serverbevestigde bezoekknop; dit helpt alleen zolang de backend bereikbaar is. Verlopen reserveringen herstellen is een expliciete regieactie. Sluit een editie pas na de bevestigingspreview; historie wordt daarmee niet fictief voltooid.

## Uitval en het fysieke Lichtbaken

Het noodpakket bevat start-/hulppunt en eindpunt Duinpad, de bekende veilige bestemming en operationele aanwijzingen. `/offline.html` geeft vooraf beschikbare algemene hulp. Probeer echt vliegtuigstand, daarna herstel en een conflicterende routewijziging op een tweede account. Een offline scan kan alleen zichtbaar wachten op servercontrole; geen offline betaling, nieuwe bestemming of definitieve beloning. De getoonde snapshotdatum maakt verouderde informatie herkenbaar.

Bij totale uitval: stop nieuwe digitale toewijzingen, gebruik vooraf gedrukte instructies en lokaal aanwezige organisatie/portofonie, leid gezelschappen naar het hulppunt en vervolgens gecontroleerd naar de finale. Geef geen ongecontroleerde huisroute uit op basis van een oude appstatus. Het fysieke baken wordt lokaal bediend. De stagingadapter meldt uitsluitend herkenbare gesimuleerde ontvangst/storing en **hardwareEnabled=false**; hij heeft geen netwerk- of hardware-uitgang. Een geslaagde adaptertest is geen fysieke installatiekeuring.

## Tijd en bewaren

| Categorie | Huidige regel | Onderhoud |
|---|---|---|
| Testeditie en synthetische scenariohistorie | Standaard 365 echte dagen vanaf bootstrap; einddatum zichtbaar. Geen nieuwe automatische delete-/afsluitjob. | Danny controleert maandelijks einddatum en benodigde verlenging vóór verval. Een gerichte verlenging gebruikt een beoordeelde editiegebonden wijziging; nooit een globale reset. |
| Opening, testvenster, routeleases en zonepauze | Editiebedrijfstijd. Een lopende bestemming blijft capaciteitsclaimen totdat scan/herstel haar vrijgeeft; na aankomst geldt een begrensde verblijfsduur. | Hervatten of expliciet leaseherstel; geen stil verdwenen lopend gezin. |
| Betaalpoging/startplaatshold | Vijftien echte minuten; retry van een open poging verlengt gecontroleerd. | Late betaling krijgt een expliciete herboek-/compensatiestatus wanneer capaciteit intussen bezet is. |
| Samenloop- en tweede-volwassene-uitnodiging | 24 echte uren; eenmalig, intrekbaar. | Maak daarna een nieuwe uitnodiging; testklok verlengt geen echte tokens. |
| Privébrowsercache | Maximaal dertig echte minuten, actor én editiegebonden. | Uitloggen/identiteitswissel wist privégegevens. Geen publieke serviceworkercache voor privé-API's. |
| Ondertekende editiekeuze | Acht echte uren, actor en HttpOnly-sessie. | Na verlopen opnieuw bevoegdheid laten controleren. |
| Auth, echte testerregistraties, financiële ledger en audit | Worden nooit door scenarioreset verwijderd. Geen nieuwe automatische anonimisering ingevoerd. | Danny beoordeelt maandelijks noodzaak en toegangsrechten; een verzoek om anonimisering/verwijdering volgt een afzonderlijke gecontroleerde procedure met behoud van noodzakelijke historie. |
| Gedownloade Nachtpas/noodpakket/QR en CSV | Lokale bestanden, geen automatische intrekking op andermans apparaat. | Gebruik eigen toestel, deel alleen noodzakelijke informatie, verwijder na de proef. Vernieuw een ingetrokken QR-bord. |
| GitHub-acceptatiescreenshots | Veertien dagen; zonder sessies, sleutels of QR-tokenregistratie. | Bewaar alleen het benodigde geschoonde bewijs langer. |
| Versleutelde releasebackup en timerinventaris | Dertig dagen als GitHub-artifact. | Controleer vóór elke grotere proef beschikbaarheid en herstelbewijs. VPS-log-/releasebewaarbeleid wordt in de echte runnerinventaris bevestigd; geen ongecontroleerde belofte over niet-gemeten timers/logrotatie. |

Een week niet testen wist de editie niet. De testklok verandert geen machineklok, TLS, JWT, providerverificatietijd of andere events. Oude 2026-onderhoudstaken blijven intact en krijgen geen nieuwe FrightNight-routegroepen of betaalrecords te verwerken.

**Resetten:** open de juiste editie, kies **Toon exacte resetomvang**, controleer slug, event-ID, run en aantallen en typ de editiecode plus bevestiging. De server archiveert uitsluitend synthetische records, trekt bijbehorende uitnodigingen/QR's in, maakt een nieuwe run en behoudt Auth, historische edities, echte testerinschrijvingen, ledger en audit. Seed daarna opnieuw. Bewaar bij een interessante regressie de oude editie en maak een kopie in plaats van alles op te schonen. Retentiecleanup is eveneens een expliciete, exact bevestigde archivering en weigert een nog beschermde editie; zij draait niet stilzwijgend op de achtergrond.

## Externe configuratie

Op 3 november 2026 is de **naam** `MOLLIE_TEST_API_KEY` niet aanwezig bij GitHub environment `staging`; er is geen sleutelinhoud opgevraagd. De werkende adapter en contracttests vervangen geen bewezen Mollie-koppeling. Voor echte PSP-testacceptatie zijn uitsluitend een geldige `test_…`-credential als server-only environmentsecret, stagingvariabele `FRIGHTNIGHT_PAYMENT_PROVIDER=mollie` en een hernieuwde gecontroleerde stagingrelease nodig, plus bewijs van bedrag, metadata, webhook/reconciliatie, mislukken/annuleren/verlopen en testrefund. De huidige geautomatiseerde hosted betaalacceptatie vereist bewust contractmodus; een providerwisseling vereist daarom tevens een passende gecontroleerde provideracceptatiepoort of een serverzijdig geïsoleerde contracttestscope. Alleen de variabele omzetten laat die gate veilig stoppen en is geen volledige activatieprocedure. Gebruik nooit `NEXT_PUBLIC_` voor de sleutel. Livecredentials worden geweigerd. Bulk-/belastingtests gebruiken contractmodus en een eigen testeditie.

De vaste grens blijft `FRIGHTNIGHT_ENABLED=true`, projectref `nocteiuvohesvqbowchw`, staginghost, canonieke slug, `FRIGHTNIGHT_MAIL_MODE=sink` en `FRIGHTNIGHT_HARDWARE_ENABLED=false`. Transactionele FrightNight-mail blijft in een editiegebonden sink zonder externe ontvanger. Bestaande Authcodes worden alleen op eigen loginverzoek verzonden. Menselijke mailboxontvangst, echte mobiele camera, fysiek baken en gecontroleerde straatpaden vereisen afzonderlijk werkelijk testbewijs.

## Backup, rollback en incident

Het laatst vooraf aangetroffen groene herstelpunt is app-SHA `ce6bbb52551c4005a24c04fe3a578a4c3860cc18`, stagingrun **41433832508**, backupartifact **13135987607**, naam `redesign-backup-staging-41433832508-1` (GitHub-retentie tot **2 december 2026**). Daar zijn versleuteling, geïsoleerd herstel, migratiedryrun, 236 bestaande tabellen en twaalf Storage-objecten gelogd. Dit bewijst niet de actuele nieuwe release. Elke nieuwe stagingrelease moet een eigen versleuteld herstelpunt en behoudsvergelijking opleveren vóór migratie/seed.

Bij een FrightNight-incident: pauzeer alleen de betreffende testeditie en leg SHA, run, tijd en correlatie-ID vast. Gebruik de bestaande immutable-release-interface voor `duindorphalloweenstg` om de laatst groene app plus bijbehorende runtimeconfig terug te zetten; controleer health, publieke pagina's en rol-/no-storegrenzen. Laat additieve schema's en historie staan. Herstel een databasebackup eerst geïsoleerd, vergelijk veranderingen en kies waar mogelijk een gerichte forward-fix. Zet geen volledige oude backup over latere 2026- of Auth-writes heen. Geen productiepromotion, DROP/TRUNCATE, remote reset, auth-delete of globale uitschakeling van bestaande cron/mail als routineoplossing. Zie de bestaande [rollbackbasis](../operations/ROLLBACK.md) met deze strengere staging-/editiegrens.
