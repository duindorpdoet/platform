# Startregie en routes beoordelen op 29 oktober 2026

Deze reparatie bouwt voort op de finale-streeftijdrelease `a4745e270710643c66c3351f8029b38c885e437f`. Software uitrollen publiceert geen startafspraken, herverdeelt geen groepen en verstuurt geen deelnemersbericht. De twee registratiekanalen worden niet veranderd. Gesloten inschrijfpagina's beloven niet langer een heropening.

## Oorzaken en veranderingen

| Melding | Oorzaak en herstel | Gerichte bewijzen |
| --- | --- | --- |
| Bevestiging noemt alleen algemene kaders | Ingevulde tijden bewezen geen opgeslagen beschikbaarheid. UI en publicatie gebruiken nu dezelfde concrete servercontrole voor modus, beschikbaarheid, poort, locatie, vensters, capaciteit en revisie. | SQL 102; `start-readiness-time.spec.ts` |
| Opgeslagen tijd lijkt verdwenen | Epoch-deduplicatie verving een optie door een andere ISO-string terwijl de select de oorspronkelijke string behield. Selectie, opties en vergelijking gebruiken nu dezelfde canonieke tijd; lokale wijzigingen blijven bij vernieuwen behouden. | `start-assignment.test.ts`; echte browserreload en opslag |
| Ingang en ouderkaart verschillen | Sommige projecties lazen ruwe coördinaten. Preview, dispatcher, vrijgegeven bestemming, navigatie en bevroren start gebruiken nu één complete gevalideerde locatiebron en bedoelde publieke ingangstekst. | SQL 100; `released-destination.spec.ts`; private-cachetests |
| Live planbord loopt vast | Herhaalde bezettings- en revisiequeries per bezoek, herberekende waarschuwingen en een onnodige globale schrijflock. Bezetting wordt per poort vastgelegd, waarschuwingen delen dezelfde bezoeken en warme reads hoeven de eventlock niet te nemen. Eerste initialisatie verwerkt maximaal twee ontbrekende groepen per uitlezing. | SQL 103; gelijktijdige lezers; prestatieproef; browserherstel na time-out |
| Circa dertig stops bij minder huizen | De oude teller deelde tijd door een bezoekcyclus. De kaart toont nu werkelijk berekende unieke bezoeken uit dezelfde routebron als de poortcontrole, of meldt dat routecontrole nog nodig is. Bestaande canonieke bezoeksleutels en herhalingsbeveiliging blijven leidend. | Bestaande bezoek-, route- en planbordcontracten; volledige SQL-suite; alleen-lezen productieoverzicht |
| Ontbrekende themawerelden | Dekking veranderde tijdens scans en was niet gekoppeld aan het sluiten van huisinschrijvingen. De bestaande compensatie krijgt een stabiele versie bij sluiting; late aanbodwijzigingen vragen aparte beoordeling. Alleen een echte gewone Anders-aankomst van het aanwezige kind kan compensatie leveren. | SQL 083/084/101; gelijktijdige aankomsten en herhalingen; exacte bewaartoets |

## Gemeten planbordprestatie

Alle metingen gebruiken uitsluitend synthetische, reeds geïnitialiseerde plannen in de geïsoleerde lokale PostgreSQL-database. Iedere proef draait terug. Dit zijn SQL/RPC-tijden, geen productiemetingen of garantie over netwerkduur. De eerste uitlezing en twee herhalingen gebruiken dezelfde fixture; de originele functies worden voor de referentie uitsluitend binnen de lokale rollbacktransactie hersteld.

| Fixture | Oude eerste uitlezing | Oude herhalingen | Nieuwe eerste uitlezing | Nieuwe herhalingen |
| --- | --- | --- | --- | --- |
| 18 groepen, 20 poorten, 360 bezoeken | 2.807 ms | 2.270 / 2.270 ms | 249 ms | 155 / 153 ms |
| 50 groepen, 30 poorten, 1.500 bezoeken | 15.120 ms | 14.558 / 15.047 ms | 962 ms | 1.033 / 1.008 ms |

Dezelfde aantallen bezoeken en waarschuwingen blijven behouden: respectievelijk 504 en 2.188 waarschuwingen. De grote fixture blijft circa 1,44 MB; de winst komt uit minder databasewerk. Drie oorspronkelijke uitlezingen riepen `group_has_visited_portal` 715.500 keer aan; met de gedeelde bezettingsprojectie zijn dat 4.950 aanroepen. De aparte koude initialisatieproef controleert batches van twee, herhaling, gelijktijdige lezers en ongewijzigde warme snapshots. De bestaande clientwachtrij blijft in gebruik.

Reproduceren: draai `scripts/acceptance/live-planboard-performance.mjs` tegen de expliciet gecontroleerde lokale database. Gebruik `BOARD_BENCH_GROUPS=50 BOARD_BENCH_PORTALS=30` voor de grote fixture en `BOARD_BENCH_REFERENCE=true` uitsluitend voor de lokale referentie. CI controleert beide actuele fixtures met `BOARD_BENCH_REQUIRE_FAST=true`.

Lokale verificatie: lint en typecheck geslaagd, 632 unittests geslaagd met één bestaande integratieskip, productiebuild en clientartifactcontrole geslaagd. Een volledige migratieherbouw slaagt met 2.688 databaseasserties in 104 bestanden. De vier nieuwe start-/ingangsbrowserproeven slagen op desktop en mobiel; alle elf bestaande en nieuwe planbordbrowserproeven slagen eveneens. De aparte initialisatie-, aankomstconcurrentie- en bewaartoetsen gebruiken uitsluitend geïsoleerde synthetische data. De exacte release krijgt daarna opnieuw de volledige bestaande CI-, staging- en productiepoorten. De gevraagde mailtestvrijstelling blijft aan één SHA en vervaldatum gebonden.

## Beoordelen en vastzetten

Volg de stappen in [het operationele runbook](RUNBOOK.md#startafspraken-beoordelen-na-de-gereedheidsreparatie-van-29-oktober-2026). Een tijdselect die nu goed wordt weergegeven vraagt geen nieuwe indeling. Herberekenen is alleen nodig bij aantoonbaar verouderde invoer of een bewust gewenste nieuwe verdeling. De eerdere [afweging voor streeftijd en maximaal dertig minuten uitloop](FINALE-STREEFTIJD-20261029.md) blijft gelden, inclusief harde gewone poortsluiting, volledige show en afzonderlijke fysieke wisseltijd.

De beschermde productierelease bewaart een alleen-lezen gecodeerd overzicht vóór migratie en na deployment als `readiness-before-production-<SHA>` en `readiness-after-production-<SHA>`. Het overzicht bevat groeps-/poortcodes, revisies, tijden, aantallen en waarschuwingen; geen deelnemersnamen, contactgegevens, adressen of coördinaten. Een pure routeprojectie gebruikt een begrensde expliciete `READ ONLY`-transactie met een bestaande bevoegde beheeridentiteit. De schrijvende planbordsnapshot wordt daarbij niet aangeroepen. Als die projectie niet beschikbaar is, vermeldt het rapport dat expliciet.

Een bestaand planbord kan bewust een oudere bewaarde route-intentie tonen. Het overzicht vermeldt daarom zowel de bronrevisie als een eventueel verschil met de actuele routecontrole. Dat verschil wordt niet tijdens deployment opgelost. Alleen startafspraken bevestigen zet ook niet alle toekomstige dynamische bestemmingen vast.

Een expliciet geaccepteerde revisie van het wereldbeleid verandert de route-invoerversie en daarmee de geldigheidscode van planbordacties. Een actie uit de oude toestand vraagt opnieuw beoordeling. Herhaald accepteren van dezelfde revisie verandert die codes niet opnieuw. De evenementinstellingen en bestaande startbevestigingen worden hiervoor niet herschreven. Het overzicht houdt bovendien de opgeslagen tijdkaders en de berekende bezoek-/finaletijden zichtbaar apart, met het gekoppelde eerste huis eenmaal geteld.

## Bewaren en terugvallen

De bestaande versleutelde backup, geïsoleerde herstelproef en vergelijking van alle bestaande velden blijven verplicht. Alleen de exact uit de oude toestand afgeleide eerste dekkingspolicy en bijbehorende sluitingsaudit mogen door deze migratie worden toegevoegd. Een afwijking van groepen, concepten, publicaties, bezoeken, zegels of instellingen stopt de release.

De herstelproef voert migraties uit als `postgres`, dezelfde rol als de gekoppelde CLI-deployment. Zo behouden bestaande functies en nieuwe afgeschermde helpers dezelfde eigenaar. Een synthetische rollbackproef controleert zowel de fout bij een afwijkende eigenaar als de werkende aanroep zonder uitvoerrechten aan anonieme of gewone gebruikers toe te voegen.

Bij een applicatieregressie geldt [de bestaande rollbackprocedure](ROLLBACK.md): selecteer via de bestaande Sites-release-interface de laatste groene immutable applicatierelease, controleer `/api/health` en de beschermde routes. De eerdere groene productierelease is `a4745e270710643c66c3351f8029b38c885e437f`. Geen force-push en geen automatische database-downgrade. Bewaar nieuwe legitieme writes; maak bij een databasefout bij voorkeur een gerichte forward-fix. De versleutelde backup en het ondertekende herstelbewijs staan bij dezelfde releaseworkflow. Een echte dataterugzetting blijft een afzonderlijke expliciete herstelhandeling.
