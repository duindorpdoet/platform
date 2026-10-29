# Finale: streeftijd en maximaal dertig minuten groepsuitloop

De bron is gecontroleerd op `d4b54ff23c0c928e21019c6631ba7b937781e130`. De gewenste groepsafronding was in planner, trigger en bulk-/verplaatscommands een harde deadline. De planner koos eerst een vertrek en reserveerde daarna per groep een finaleplek. Daardoor konden vroeg verwerkte groepen de goede late plekken bezetten en werd een andere gewone route sterk ingekort. Het live planbord behandelde daarnaast een historisch uit de eindwens gekopieerde gewone stop nog als harde gezinsgrens.

Ook het inschrijfformulier en de voorkeureneditor benoemen nu de afronding inclusief laatste poort, zonder een eindwens als gewone stop te presenteren. Een achtergebleven gewoon-stopveld in een oud inschrijfconcept wordt niet opnieuw als harde grens uitgelegd.

De wijziging gebruikt de bestaande stemmen per oorspronkelijke inschrijving, frequentie, totale absolute afwijking en vroegste tie-break. Een minderheidswens wordt geen groepsveto. Los opgegeven gewone stopgrenzen blijven gelden. Nieuwe exacte voorkeuren schrijven geen afgeleide gewone stop meer; historische records worden niet opgeschoond of herschreven.

## Tijd en serverbeleid

`app_private.group_end_overrun_seconds()` definieert één serverconstante van 1.800 seconden. `admin_startregie_snapshot.settings.maxGroupOverrunSeconds` levert hetzelfde beleid aan de planner. Voorstellen kunnen de serverconstante niet wijzigen. De doelafronding blijft de dominante eindwens; de extra ruimte is alleen een geldigheidsgrens.

| Tijd | Betekenis |
| --- | --- |
| Start | Het fysieke vertrek; maximaal één groep per poort en heel tienminutenmoment |
| Gewone stop | Einde van gewone bezoeken; begrensd door globale en expliciete gewone stops |
| Finale-aankomst | Begin van de show, na de afzonderlijke overdracht |
| Groepsafronding | Aankomst plus show; maximaal dominante eindwens plus 1.800 seconden |
| Fysiek einde | Aankomst plus show en wisseltijd; geheel binnen definitieve sluiting én één fysieke poortopening |

De afzonderlijke finaleopening, laatste aankomst, definitieve sluiting en fysieke poortvensters worden niet verlengd door de migratie. De effectieve capaciteit respecteert zowel de finale-instellingen als de fysieke groeps-, kinder- en totale kinderlimieten. Voor een eindwens van 21:00, een show van tien minuten en twee minuten wisseltijd vraagt de volledige speling om aankomst uiterlijk 21:20 en fysieke beschikbaarheid tot minimaal 21:32. Voor 20:30 geldt een groepsafronding uiterlijk 21:00.

Het scherm waarschuwt concreet als de volledige speling niet in het huidige venster past. Een korter toegestaan venster kan wel een goede eerdere oplossing bieden. De alleen-lezen releasecontrole meldt de werkelijk ingestelde vensters en geanonimiseerde timingalternatieven, zonder deelnemersrecords als fixture of rapportbestand op te slaan. Harde sluitingen vereisen een afzonderlijke, expliciete beheerwijziging na bevestigde beschikbaarheid.

## Afweging en begrensde verdeling

De planner beoordeelt vertrek en finaleplaats samen. De kosten bestaan uit:

- startafwijking: 0,5 per minuut;
- te vroeg afronden: 1 per minuut;
- uitloop: 2 per minuut, plus 5 zodra uitloop nodig is;
- verloren bruikbare gewone routetijd: 2 per minuut, plus verlies² / 30;
- noodzakelijke wachttijd na gewone sluiting: 1,5 per minuut, afzonderlijk benoemd als wachttijd.

Zo scoort 20:55 beter dan 21:10 bij gewenst 21:00, en 21:05 beter dan 19:48 met tientallen minuten routeverlies. Bij gelijke absolute eindafwijking wint de eerdere afronding. Wachten om alleen een mooiere eindtijd te tonen verbetert de score niet. De planner verandert geen bezoekduur.

Er worden drie deterministische volgordes onderzocht: vroegste uiterste finaleplaats met weinig vertrekalternatieven, startvoorkeur en omgekeerde eindvolgorde. Daarna worden maximaal acht sterk benadeelde groepen met vier nabije concurrenten in beide volgordes opnieuw ingevoegd. Meer ingeplande groepen gaat vóór lagere totale kosten. Bestaande beschermde afspraken worden nooit meegenomen in de herschikking. Dit is een begrensde zoekmethode, geen bewijs van een wereldwijd optimum; sterke inkorting wordt zichtbaar gemeld.

## Synthetische reproductie

Alle hieronder genoemde groepen, reserveringen en tijden zijn synthetische regressie-invoer. Vijf finaleplekken van twaalf minuten bezetten 19:54–20:54. Startvoorkeur is 18:30, het beschikbare vertrek is 18:40 en gewone poorten sluiten 20:30.

| | Strikte oude eindgrens | Nieuw beleid |
| --- | --- | --- |
| Gewenst klaar | 21:00 | 21:00 |
| Vertrek | 18:40 | 18:40 |
| Gewone poorten tot | 19:27 | 20:30 |
| Finale-aankomst | 19:42 | 20:54 |
| Show afgerond | 19:52 | 21:04 |
| Fysieke bezetting tot | 19:54 | 21:06 |
| Eindafwijking | 68 minuten eerder | 4 minuten uitloop |
| Onnodig verloren gewone routetijd | 63 minuten | 0 minuten |

De nieuwe oplossing heeft negen minuten noodzakelijke wachttijd tussen de gewone overdracht en de vrije finaleplek. Die wordt expliciet getoond en telt niet als bezoektijd.

## Opslag, live en verificatie

De nieuwe migratie werkt de gedeelde tijdvalidatie, revisietrigger, bulkverdeling, nieuwe groepen, handmatige verplaatsing, capaciteit, snapshots, routeverwachting en live finalereservering bij. Publicatie controleert dezelfde grenzen. Reserveringen en revisiealternatieven tellen per fysieke groep één keer op ieder werkelijk overlappend tijdstip. Andere groepen blijven capaciteit bezetten. Bij historische snapshots zonder opgeslagen eindvoorkeur wordt de bestaande meerderheid gebruikt voor de grens van toekomstige reserveringen; de gepubliceerde gewone stop en lopende route worden niet herschreven. Eventlocks serialiseren gelijktijdige planningsschrijvers; live herhaling hergebruikt dezelfde reservering.

De gerichte domeinproeven staan in `lib/domain/route-planner.overrun.test.ts`; databasecontracten in `supabase/tests/098_completion_target_overrun.sql`. Ze toetsen de score, de synthetische reproductie, groepsgrenzen tot op de seconde, show versus wissel, afzonderlijke sluitingen, beide bulkcommands, directe API, publicatie, snapshots en dispatch na de oude strikte eindwens. De twee echte gelijktijdigheidsproeven staan in `scripts/acceptance/finale-overrun-concurrency.mjs`. De browserproef `tests/e2e/finale-target.spec.ts` controleert de zichtbare tijden, uitleg en conceptopslag op desktop en mobiel zonder nieuwe deelnemersmail. Deze proeven zijn opgenomen in CI.

Lokale verificatie geslaagd: `pnpm verify` (lint, typecheck, 610 geslaagde unittests en één bestaande integratieskip, productiebuild en clientartifactcontrole), volledige migratieherbouw en 2.552 pgTAP-controles in 100 bestanden. De bestaande vertrekconcurrentie, nieuwe finaleconcurrentie en beide browserproeven (nieuwe uitloop plus bestaande groepsketen) slagen. Schemalint geeft alleen bestaande waarschuwingen; security advisors geeft geen fouten. De bestaande `pg_net`-waarschuwing over het public-schema blijft bestaand; nieuwe private helpers geven geen publieke uitvoerrechten. De release behoudt de versleutelde backup/herstelproef en de eis dat productie exact de geslaagde stagingcommit krijgt. De expliciet gevraagde mailtestvrijstelling geldt alleen voor de begrensde release-SHA. Ook de Poortkamer-proef die een echte Auth-e-mailcode aanvraagt volgt nu die bestaande vrijstelling; de overige Poortkamer-proeven blijven vereist.

## Bestaande voorstellen opnieuw berekenen

Deployment voert uitsluitend definities in en publiceert of herschrijft geen planning. Kies voor bewerkbare bestaande groepen **Groepen automatisch over startpunten verdelen**, beoordeel afronding, routeverlies, uitloopreden en conflicten, en gebruik **Conceptslotverdeling opslaan**. Bevestigen/publiceren blijft een afzonderlijke bestaande beheerhandeling. Bevestigde of gepubliceerde afspraken worden niet automatisch herverdeeld; begonnen routes worden niet vervangen. De uitrol roept geen publicatiecommand of deelnemerscommunicatie aan.
