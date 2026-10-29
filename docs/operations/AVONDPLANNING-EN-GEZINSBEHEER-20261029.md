# Gezamenlijke avondplanning, gezinsbeheer en blijvende poortcodes

Deze uitbreiding volgt op [de gereedheidsreparatie](HALLOWEEN-GEREEDHEID-20261029.md) en [de finale-streeftijd](FINALE-STREEFTIJD-20261029.md). Uitrollen wijzigt geen bestaande startafspraken, route-intenties of begonnen routes en verstuurt geen deelnemersbericht. De publieke inschrijfschakelaars blijven behouden.

## Routes opnieuw berekenen met vaste afspraken

1. Open het **Live planbord** en kies **Routes opnieuw berekenen met bevestigde starts**. Dit berekent uitsluitend een voorstel met één gedeelde kalender voor alle fysieke poorten.
2. Beoordeel de vergelijking per groep en huis: gewone bezoeken, bezoektijd, lopen, onbenutte tijd, eindafwijking en poortgaten. Deze knop behoudt alle opgeslagen starts en geldige gereserveerde finales. Een ongeldige afspraak vraagt eerst een afzonderlijke correctie via Startregie.
3. Los alle blokkades op. Controleer een onbekende toegankelijkheidsbehoefte bij de gezinsinschrijving en de feitelijke toegankelijkheid van de poort. Een vrije opmerking wordt geen verzonnen fysieke eis of stilzwijgend akkoord.
4. Geef een beheerreden, bevestig de beoordeling en kies **Beoordeeld routeconcept opslaan**. De server controleert bronhash, actuele bordversie en gezamenlijke capaciteit opnieuw en slaat alle intenties atomair op. Bij gewijzigde invoer moet het voorstel opnieuw worden berekend.
5. Alleen als start- of finaleafspraken bewust moeten veranderen, gebruik je de bestaande Startregie-conceptflow. **Startafspraken bevestigen en versturen** blijft een afzonderlijke publicatie- en communicatiehandeling.

Alleen vernieuwen berekent of accepteert geen nieuwe routes. De eerste uitlezing maakt hoogstens ontbrekende planmetadata; zij vult geen onafhankelijke routes meer in. Nieuwe routes gebruiken een expliciet beoordeelde gezamenlijke versie. Begonnen routes en bewezen bezoeken blijven beschermd. Wijzigingen aan vensters, markers, ingedeelde groepssamenstelling of beleid maken een oud voorstel herkenbaar verouderd. Publicatiemetadata, voortgang en nieuwe nog niet ingedeelde inschrijvingen veranderen op zichzelf de semantische route-invoer niet.

De planner gebruikt meerdere deterministische constructies en begrensde lokale herverdeling. De volgorde is: harde geldigheid, eerlijke bruikbare bezoeken per groep, eindvoorkeur, spreiding over geschikte huizen en daarna lopen en behoud van goede conceptonderdelen. Hij bewijst geen wereldwijd optimum. Een onhaalbare verdeling blijft geblokkeerd en vermeldt het concrete knelpunt.

## Tijden en capaciteit

- Gewenst einde is **afronding van de finale**. Maximaal dertig minuten groepsuitloop omvat de hele show. Wisseltijd telt voor fysieke bezetting en definitieve sluiting, niet als bezoektijd. De bestaande meerderheidsweging en tie-breaks blijven behouden.
- Vroeg afronden en uitloop worden beide bestraft; bij gelijke absolute afwijking heeft op of vóór de streeftijd voorrang. Een passende route zonder uitloop krijgt voorrang. Een kleine uitloop kan beter zijn dan tientallen minuten onnodig routeverlies. De planner verzint geen wachttijd of langere bezoeken.
- Gewone aankomst is nooit vóór opening en blijft strikt vóór het einde van de ontvangst. Bezoek plus buffer passen binnen de fysieke eindgrens. De afzonderlijke gewone einduitloop is maximaal vijf minuten en is nul bij een expliciete harde sluiting.
- Finale gebruikt de doorsnede van eigen beschikbaarheid en evenementkaders. Laatste aankomst, show en wisseltijd moeten allemaal passen. Groepsuitloop vergroot geen huis- of finalecapaciteit.
- De minimumafstand tussen aankomsten geldt per fysiek huis: standaard vijf minuten, per poort instelbaar op bijvoorbeeld tien. Overlap kan daarna alleen binnen groeps- en kindercapaciteit. Een show van zes minuten met één groep tegelijk vraagt dus minstens zes minuten afstand.
- Vertrekken blijven maximaal eenmaal per startpoort per tienminutenslot; verzamelen heeft eigen capaciteit. Alternatieve revisies van dezelfde groep tellen niet dubbel. Een administratieve start is geen fysiek huisbezoek.
- Elk fysiek huis telt eenmaal. Aliassen van hetzelfde huis leveren geen extra capaciteit of bezoek op. Wereldbonuszegels veranderen die telling niet.

Het bord tekent echte bezoekduur en buffer apart. Brede labels vergroten het fysieke tijdvak of het aantal conflictrijen niet. Klik, hover, toetsenbord en mobiele details tonen de exacte tijden en grenzen.

## Gezinsinschrijvingen beheren

De acties staan onder **Inschrijvingen**, voor de bestaande bevoegde organisatierollen. Een gezin is één inschrijving met ouder en kinderen; een loopgroep bevat meerdere gezinnen en een samenloop is een voorkeurrelatie.

| Actie | Werking |
| --- | --- |
| **Inschrijving toevoegen** | Eén ouder met één of meer kinderen aanmaken, ook bij gesloten publieke inschrijving. Optioneel direct een groep/samenloop kiezen. Invoer blijft bij fouten behouden. Bij een bestaande inschrijving wordt bewerken aangeboden. |
| **Inschrijving bewerken** | Kinderen toevoegen, corrigeren of deelname verwijderen binnen hetzelfde gezin, dezelfde groep en samenloop. Identiteiten, betalingen, paspoorten en bezoekhistorie blijven behouden. Het laatste kind kan niet ongemerkt uit een actieve inschrijving verdwijnen. |
| **Verplaatsen naar andere groep** | Alleen dit gehele gezin atomair verplaatsen. Andere gezinnen en bevestigde startafspraken blijven behouden. De doelgroepafspraak geldt voor dit gezin; alleen deze ouder krijgt de gerichte wijzigingsmail. Een samenloop verhuist niet automatisch mee. |

**Aanmaken → uitnodiging → juiste geverifieerde OTP- of Google-inlog → geactiveerde deelname.** Activatie maakt geen betaling voldaan. Toegewezen kinderen reserveren al capaciteit terwijl activatie wacht. Zonder groep wordt geen bevestigde start beloofd. Er wordt geen geverifieerd ouderaccount namens iemand aangemaakt.

Een oude sessie activeert niet op de achtergrond. Een reeds ingelogde ouder kan de beveiligde uitnodiging expliciet claimen. Een verlopen uitnodiging kan opnieuw worden verstuurd; een gecorrigeerd e-mailadres of nieuwe uitnodiging trekt de oude claimreferentie in. Beheer toont activatie- en mailstatus, **Uitnodiging opnieuw versturen** en **E-mailadres corrigeren vóór activatie**.

**Kind bewerken → hetzelfde gezin en dezelfde groep blijven gekoppeld.** Alleen de deelname wordt verwijderd, niet het account, de kindidentiteit of historie. De server controleert ook werkelijke vertrek-, verzamel-, huis- en finalecapaciteit. Een gewijzigde groepssamenstelling kan een nieuwe routebeoordeling vragen; de bevestigde start wordt daardoor niet automatisch gewijzigd.

**Gezin verplaatsen → doelgroepafspraak geldt → alleen dit gezin krijgt wijzigingsmail.** Dezelfde groep is een no-op. Retries zijn idempotent; stale versies en volle doelen worden geweigerd. De enige bevoegde leider kan niet ongemerkt de brongroep verlaten. Bij een begonnen groep volgt een gerichte blokkade. Oude groepsrechten en verouderde privé-cache verdwijnen; toekomstige adressen blijven tot de bestaande vrijgave afgeschermd. Wachtende verouderde mails worden opnieuw gecontroleerd. Een providerstoring bewaart de geslaagde wijziging en herhaalbare mailopdracht.

## Zichtbare en blijvende huis-QR en handmatige codes

Open bij **Mijn huis** de QR-weergave. De keuze blijft bij herladen en wisselen tussen eigen huizen behouden. Zichtbare QR en handmatige code horen bij hetzelfde opgeslagen paar; een witte marge maakt de QR scanbaar.

Oude poorten hadden soms alleen credentialhashes zonder terugleesbaar afdrukmateriaal. Een oudere weergave kon vernieuwde codes bovendien uitsluitend in browsergeheugen bewaren. De bevoegde serverroute levert nu bestaand versleuteld materiaal of maakt onder een lock één aanvullend blijvend paar. Bestaande geldige legacycodes blijven daarbij werken. Gewoon openen of herladen roteert de code niet en verandert geen route-invoer.

De nieuwe blijvende codes verlopen niet automatisch. Alleen een expliciete bevoegde intrek- of vernieuwactie vervangt hun geldigheid. Een tijdelijke fout laat een al getoond paar zichtbaar; verlies van toestemming wist het wel. Een onduidelijke vernieuwrespons wordt met een uitlezing hersteld, zonder ongemerkt een tweede vernieuwing te starten. Ruwe codes worden niet in browseropslag, auditrapporten of logs bewaard.

## Verificatie en actuele routevergelijking

De volledige releasegate blijft verplicht, met de aangevraagde mailtestvrijstelling aan één SHA en vervaldatum gebonden. Autorisatie-, activatie-, outbox-, domein-, database-, QR- en browsercontroles blijven uitgevoerd. Er worden geen echte deelnemersmails of echte inschrijvingen als productietest gebruikt.

De vaste planbordprestatieproef gebruikt niet-lege synthetische groepen met daadwerkelijk toegewezen kinderen. Lege toekomstige groepen tellen terecht niet als fysieke bezetting en zijn daarom geen representatieve capaciteitsproef. Alle benchmarkdata en lokale referentiefuncties vallen binnen een rollbacktransactie. Waarschuwingcodes en aantallen maken verschillen tussen historische en huidige regels expliciet. Batching van fysieke headwaygegevens moet exact dezelfde huidige waarschuwingen opleveren; zij versoepelt geen regel. Vensters, de headway van alle fysieke aliassen en finalebeschikbaarheid worden per poort binnen dezelfde statement vastgelegd. De bestaande servervalidator haalt deze gegevens bij iedere aanroep opnieuw uit de database. Beide gebruiken één private capaciteitspredicate; clients kunnen geen eigen context aanleveren.

De oorspronkelijke fysieke referentie en de onafhankelijk gecontroleerde eindversie leveren op de schone lokale database de volgende SQL/RPC-tijden op. Iedere groep heeft één echt toegewezen synthetisch kind. Dit zijn geen productiemetingen of netwerkgaranties.

| Groepen / poorten / bezoeken / kinderen | Vóór batching: eerste / herhalingen | Na batching en contextcache: eerste / herhalingen | Waarschuwingen na |
| --- | --- | --- | --- |
| 18 / 20 / 360 / 18 | 5.141 / 5.185 / 5.056 ms | 425 / 369 / 410 ms | 1.137 |
| 50 / 30 / 1.500 / 50 | meer dan 20.000 ms, time-out | 3.896 / 3.968 / 4.014 ms | 5.623 |

De fysieke referentie voor achttien groepen behoudt precies dezelfde 1.137 waarschuwingen en codeaantallen. De grotere referentie breekt bij twintig seconden af; daarvoor wordt geen volledig waarschuwingtotaal verzonnen. De differentiële SQL-regressie vergelijkt volledige huidige waarschuwingsobjecten met de oorspronkelijke fysieke functie, inclusief aliassen, microseconden, toegankelijkheid, dubbele sequence-nummers en echte buffers van begonnen nul-kindgroepen. Alle 49 controles slagen. Een afzonderlijke oracle bevat de volledige oorspronkelijke intervalvalidator en vergelijkt 1.015 gevallen met de nieuwe gedeelde predicate. De 26 aanvullende asserties bewaken ook groeps- en kindercapaciteit, halfopen bezetting, cumulatieve historische kinderen, volledige show plus buffer, microseconden, NULL-finalebevoegdheid en private uitvoering. De vaste CI-grens blijft acht seconden; de langzaamste onafhankelijke lokale grotere uitlezing hield circa 3,99 seconde marge. De volledige herbouw slaagt met 3.104 asserties in 114 SQL-bestanden en nul database-lintfouten.

Reproduceren met de bestaande bewaakte lokale Supabase-omgeving: draai `scripts/acceptance/live-planboard-performance.mjs` met `BOARD_BENCH_GROUPS=18 BOARD_BENCH_PORTALS=20` of `BOARD_BENCH_GROUPS=50 BOARD_BENCH_PORTALS=30` en `BOARD_BENCH_REQUIRE_FAST=true`. Voor uitsluitend de eerdere fysieke waarschuwingsfunctie gebruik je `BOARD_BENCH_PHYSICAL_REFERENCE=true` en `BOARD_BENCH_REQUIRE_FAST=false`. Die lokale referentie behoudt alle huidige fysieke regels en wordt teruggedraaid; de oudere `BOARD_BENCH_REFERENCE=true` heeft andere waarschuwingssemantiek en mag niet tegelijk worden gekozen. Een referentietime-out wordt als ondergrens vermeld, niet als afgeronde meting.

De productierelease bewaart gecodeerde, alleen-lezen **audit**, **kalender** en **nieuw voorstel** vóór en na de uitrol. Opgeslagen intenties veranderen niet door een verbeterd voorstel te berekenen. Het opleverrapport vermeldt echte geldigheid, bewaarde afspraken, verschillen per groep/huis en eventuele menselijke verificaties die nog nodig zijn. Een ontbrekend of geblokkeerd voorstel wordt niet als geldig gepresenteerd. De audit bevat geen namen, contactgegevens, adressen, coördinaten of ruwe codes.

## Checkpoint en herstel

Versleutelde backup, geïsoleerde herstelproef, migratie-allowlist en exacte bewaring van bestaande rijen/kolommen blijven de releasepoort. Migraties voeren geen gezinsverplaatsing, routeherberekening, herpublicatie of mailcampagne uit. Ontbrekend QR-afdrukmateriaal wordt pas bij bevoegd openen veilig aangemaakt.

De laatste groene applicatierelease vóór deze uitbreiding is `e05b00257a59ab4c526838b2c3405daa5450fe31`. Bij een applicatieregressie volgt [de bestaande rollbackprocedure](ROLLBACK.md): selecteer de vorige groene immutable Sites-release en controleer de gedeployde SHA. Migraties blijven forward-only; geen blinde database-downgrade of verlies van nieuwe legitieme writes. Versleutelde backup en ondertekend herstelbewijs horen bij dezelfde deploymentrun.
