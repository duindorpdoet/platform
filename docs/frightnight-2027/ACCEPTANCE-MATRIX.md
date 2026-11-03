# Acceptatiematrix — alle 87 pakketproeven

Peildatum: 3 november 2026, vóór de nieuwe stagingrelease. **Geen van deze 87 eindacceptaties is hiermee volledig op de gepubliceerde nieuwe staging-SHA geslaagd verklaard.** Iedere rij houdt de resterende echte proef zichtbaar. De lokale databasebewijzen zijn uitgevoerd in een geïsoleerde PostgreSQL17.6-database; contractadapters zijn geen echte PSP-, cameratoestel-, mail-, straatroute- of hardwareacceptatie.

Bronnen: `05-testen/ACCEPTATIETESTS.md` (82 IDs) en `05-testen/MAANDENLANG-TESTEN.md` (RET-01 t/m RET-05). De lokale titels hieronder verwijzen naar die exacte proeven. Er ontbreken geen IDs en er zijn geen eigen IDs als vervanging toegevoegd.

## Bewijs en geldigheid

| Code | Werkelijk uitgevoerd bewijs | Grens |
|---|---|---|
| LDB | [backend-database-report.json](validation/backend-database-report.json): laatste vastgelegde pgTAP-uitslag en bron-SHA256; [SQL-contracten](../../supabase/tests/127_frightnight_2027_core.sql) | Lokale transacties rollen terug. Het rapport noemt concrete migratie-/testhashes; een latere bronwijziging vraagt nieuwe uitvoering. Geen echte mail/PSP. |
| LRACE | De concurrencysectie van hetzelfde rapport; [db-concurrency.py](../../scripts/frightnight/db-concurrency.py): twaalf gelijktijdige starts, twee replayrequests, refund/scanrace | Nul overboeking en eenmaal bezoek/award in lokale fixture. Dit is een integriteitsrace, geen stagingpiek-/duurtest of p95/p99-begroting. |
| LU | [security-review-report.json](validation/security-review-report.json) plus genoemde `lib/frightnight/*.test.ts` | Gerichte adapter-/body-/QR-/refundtests; overige modules volgen hun laatste gezamenlijke testuitvoer. Een verwijzing naar aanwezige bron is geen zelfstandig geslaagde browserproef. |
| Audit deels | [ENVIRONMENT-AUDIT.md](ENVIRONMENT-AUDIT.md) en gerichte metadataquery | Read-only audit van bestaande staging. VPS-inventaris en twee echte jobcycli met nieuwe editie zijn aparte releasegates. |
| Historisch herstel | Backup/restore-run41433832508 op ce6bbb52551c4005a24c04fe3a578a4c3860cc18 | Oud herstelbewijs; niet de nieuwe release of een nieuw 2027-scenario. |
| Open / Extern geblokkeerd / Fysiek open | Geen volledig uitgevoerd passend bewijs | Uitvoeren op juiste scope of ontbrekende credential/werkelijk toestel/operationele installatie oplossen. |

De actuele lokale productiebuild **Ok5RjR2fex_g9bgq4d5YE** is volledig gebouwd en gecontroleerd: **1514 appchecks**, zes optionele integratieskips en **6/6 Node-uitvoergrenzen**. Het [bronhashrapport](validation/application-verify-report.json) en [bewijsregister](evidence/README.md) noemen de concrete broncontext. De verse databaseproef telt **646/646** (550 kern + 96 toegang), met races en 31 afgeschermde tabellen. Werkelijke wederzijdse foto-upload/download via Storage HTTP blijft een gepubliceerde acceptatiegate.

De vorige build **fzribBblz0y5tNosd_-R-** heeft **96 geslaagde lokale browserchecks**: 23 publieke, 24 download-/klok-/privacy-, 27 aanvullende scenario-, 12 HUI-02- en 10 spel-/bakencontroles. De huidige build voegt uitsluitend een zichtbare regiefotolink toe; de gerichte browserherproef slaagt voor 23 publieke, 12 HUI-02- en 11 fotolinkpresentatiechecks met eigen buildbewijs. De fotolinkfixture bewijst geen Storage HTTP. De eerdere passage op **5AlZTx-My0ydPqjQnmPQY** behoudt haar 24 uitkomsten en broncontext. Eerdere contact-, quote- en regieproeven blijven eveneens met hun oorspronkelijke builds herkenbaar.

De hosted scripts zijn uitsluitend na geverifieerde binding, backup/restore, behoud en deployment toegestaan. Zij gebruiken de werkelijk gepubliceerde SHA en een eigen nieuwe testscope. Geen lokale uitkomst vervangt een externe PSP-, echte camera-, fysieke straat-/baken- of gepubliceerde duurproef.

## Registratie per pakket-ID

Alle rijen hebben eindstatus **open op nieuwe staging**. De bewijskolom beschrijft uitsluitend het werkelijk aanwezige lokale deelbewijs en de noodzakelijke aanvulling. `Extern geblokkeerd` betekent geen bewezen PSP-test omdat de stagingsecretnaam `MOLLIE_TEST_API_KEY` bij controle ontbrak. Er wordt geen OTP aangevraagd om een vakje groen te maken.

| ID | Lokale bewijssoort | Deelbewijs en resterende acceptatie |
|---|---|---|
| ENV-01 | LDB | Sink heeft geen ontvangerkolom; synthetische gezinnen zonder oud huishouden. Hosted sink- en bezorgcontrole open. |
| ENV-02 | LDB, LU | Nieuwe payment/sinktabellen en retry raken geen legacy-outbox. Echte providerlink/refund nog open. |
| ENV-03 | Open | Croncatalogus geaudit; twee echte cycli plus nieuwe editie observeren na release. |
| ENV-04 | LU | Envvalidator weigert onveilige mailmodus. Gecontroleerde foutinjectie op staging nog open. |
| ENV-05 | LDB | Lokale legacy-aantallen en bewaarde dummyhistorie gelijk. Echte stagingbehoudsvergelijking opnieuw vereist. |
| INS-01 | LDB | Serverprijs, consent en idempotentie deels bewezen; vierpersoons-UIreis en dubbelklik op staging open. |
| INS-02 | LDB | Consent-/databasegrenzen deels bewezen; alle ongeldige invoer incl. Authmailadres via echte app open. |
| INS-03 | Extern geblokkeerd | MOLLIE_TEST_API_KEY ontbreekt in stagingsecretnamen. Contractbetaling is afzonderlijk gelabeld. |
| INS-04 | LDB | Onbetaald starten geweigerd; return-URL zonder betaling nog via gepubliceerde app uitvoeren. |
| INS-05 | LU | Adapter valideert statusvormen; echte PSP mislukken/open/annuleren/verlopen niet uitgevoerd. |
| INS-06 | LDB, LU | Dubbele/out-of-order providerbevestiging zonder dubbele ledger lokaal; vijf echte webhookreplays open. |
| INS-07 | LDB | Holds, verlopen hold, late betaling en herboeken lokaal. Gelijktijdige laatste startplaatsen op staging open. |
| INS-08 | LDB, lokale browser | Eigen contactwijziging, tweede tab en stale conflict lokaal groen; voorkeuren/herboeken lokaal getoetst. Gepubliceerde contact-/startwijziging en tweede toestel open. |
| INS-09 | LDB, lokale browser | Vanaf eerste betaalpoging staan personen/tocht/bedrag vast, ook na failed/expired of tariefwijziging; duidelijke organisatie-uitleg en gemanipuleerd verzoek409 lokaal bewezen. Start/contact/comfort blijven werken; refund wordt niet heractiveerd. Gepubliceerde herhaling open. |
| INS-10 | LDB, LRACE, LU | Refundledger/scanrace en providerbindings lokaal; echte PSP-testrefund niet uitgevoerd. |
| QR-01 | Fysiek open | Geen echte Android-/iOS-cameratest uitgevoerd. HTTPS-camera-implementatie is geen toestelbewijs. |
| QR-02 | LDB | Handmatige servercodevalidatie lokaal; geweigerde cameratoestemming en dezelfde UIflow open. |
| QR-03 | Open | Editieklok en tijdgrenzen aanwezig; beide starttijdscenario's op staging uitvoeren. |
| QR-04 | LDB | Na venster gecontroleerd herstel naar Duinpad lokaal; late start met echte looptijden open. |
| QR-05 | LDB | Verkeerde start-/zonecode en oude routeversie lokaal; alle oude-editiecodevarianten open. |
| QR-06 | LDB, LRACE | Stabiel commandresultaat en één bezoek/award onder twee gelijktijdige replayrequests lokaal. Een replay projecteert daarnaast de actuele toegestane snapshot opnieuw, zodat ingetrokken rechten of gewijzigde routes niet terugkeren. |
| QR-07 | LRACE | Twee gelijktijdige identieke scans lokaal: één bezoek/award; echte tabs/apparaten op staging open. |
| QR-08 | Open | Autoritatieve serveropslag aanwezig; refresh en tweede zelfstandig toestel open. |
| QR-09 | LDB | Deelnemer heeft eigen snapshot zonder regierooster; volledige response-/kaartinspectie op staging open. |
| QR-10 | LU | QR-exportkey actor/editie/registratie/run lokaal; echte intrekking en vervangend geprint bord open. |
| QR-11 | LDB | QR-vrijbeleid en opgeslagen released-scanmethode lokaal; heen/terugsynchronisatie na herstart open. |
| ROU-01 | LDB | Milde selectie, verlaagde spanning en Duinpadfinale lokaal; volledige wandeling open. |
| ROU-02 | LDB | Lagere intensiteit en strengste groepscomfort lokaal; alle effecten tijdens tocht op staging open. |
| ROU-03 | LDB | Zonepauzebeleid lokaal; sluiten huidige zone met live deelnemer en alternatief open. |
| ROU-04 | LRACE | Elf van twaalf gezinnen wachten veilig bij volle passende zones lokaal; UI-uitleg staging open. |
| ROU-05 | LDB, LRACE | Twaalf starts tegelijk, nul overboeking lokaal; herhalen op geverifieerde stagingeditie open. |
| ROU-06 | LDB | Verlopen lease vereist hervatten; precies één herstelde bestemming. Stagingherhaling open. |
| ROU-07 | LDB, LRACE, lokale browser | Bewonerswaarneming en appclaims tellen bekende personen éénmaal; extra bezoekers, verouderde waarneming, expliciete leegbevestiging en vijf echte races lokaal bewezen. Nieuwe stagingherhaling open. |
| ROU-08 | Open | Loop-/bezoek-/sluitmarge in deterministische selectie; specifieke grensproef nog uitvoeren. |
| ROU-09 | Open | Skipcommand aanwezig; oude QR zonder award en terugtoewijzing nog expliciet testen. |
| ROU-10 | LDB | Venstereinde/herstel naar Duinpad lokaal; gemeten verre locatie en wandelmarge open. |
| ROU-11 | Open | Volle/gesloten finale met hulp- en herstelpad nog specifiek accepteren. |
| ROU-12 | LDB | Expliciet stoppen geeft finale zonder alle bezoeken; alle gesloten gewone zones nog testen. |
| ROU-13 | LDB | Stoppen geeft één Duinpadbestemming; rustige/stepvrije fysieke terugkeer open. |
| SAM-01 | LDB | Twee betaalde accounts stemmen in en krijgen gedeelde route lokaal; twee echte toestellen open. |
| SAM-02 | Open | Serverregels aanwezig; alle drie afwijzingsvarianten nog met bewijs uitvoeren. |
| SAM-03 | LDB | Vier gezamenlijke personen en strengste voorkeuren lokaal; exact vier-plus-vijfscenario open. |
| SAM-04 | LDB | Tweede actor bedient route in lokale fixtures; echte contactpersonen via app open. |
| SAM-05 | LRACE | Receipt-replayrace lokaal; herhaalde gelijktijdige scans van verschillende samenloople­ den open. |
| SAM-06 | LDB | Aansluiten tijdens wandelen lokaal; persoonlijke eerdere awards en geen retroactieve beloning specifiek open. |
| SAM-07 | LDB | Verlaten levert twee coherente routes lokaal; herhaalde leave-versus-scanrace op staging open. |
| SAM-08 | Open | Eventlock/versies en voorkeuraggregatie aanwezig; join-versus-voorkeurswijzigingrace open. |
| SAM-09 | Open | Afgeronde/actieve combinatie nog specifiek uitvoeren en geschiedenis vergelijken. |
| HUI-01 | LDB, LU | Eigen aanvraag, geverifieerd contact/ligging en Storagepredicate lokaal; echte upload/browserflow open. |
| HUI-02 | LDB | Versiegebonden wijzigingsverzoek/afwijzing met private reden, herindienen en expliciete locatieherbevestiging vóór goedkeuring lokaal bewezen. De echte lokale regie-/bewoners-UIflow slaagt voor 12 controles op de actuele build; nieuwe stagingherhaling blijft vereist. |
| HUI-03 | LDB | Snoep-/spanning- en capaciteitsgrenzen deels lokaal; volledige bewerking en routereactie open. |
| HUI-04 | LDB | Pauze, vroege afloop en geen heropening buiten uren lokaal bewezen; echte browserherhaling open. |
| HUI-05 | LU | Uitgegeven QR-exportreceipt lokaal; afdruk en echte camerascan van fysiek bord open. |
| ACT-01 | LDB | Hele gezin, herhaalboeking en laatste capaciteit lokaal; gelijktijdige boeking/tweede toestel open. |
| ACT-02 | LDB | Annuleren geeft plaatsen eenmaal vrij lokaal; toegewezen medewerker en onbevoegde inzage open. |
| KID-01 | LDB, lokale browser | Alle drie raadsels en drie spelinterfaces werkelijk bediend met fout/herkansing op actuele build; gepubliceerde herhaling open. |
| KID-02 | LDB, lokale browser | Alle zes voltooide spellen blijven na refresh en tweede onafhankelijke browsercontext bewaard; zes echte commandreplays geven geen dubbele award. Fysiek tweede toestel/gepubliceerde herhaling open. |
| KID-03 | Open | Server valideert quests/antwoorden; willekeurige award-ID en clientmanipulatie nog accepteren. |
| BAK-01 | LU | Stagingbakenadapter ondersteunt rehearsal zonder hardware; geen fysiek lichtbewijs. |
| BAK-02 | LDB | Finalescan en digitale bakenaward na enkele huizen lokaal; drie UIstappen/Nachtpas op staging open. |
| BAK-03 | LU | Adapter zonder netwerkuitgang; hardwareuitvoer false. Fysieke onafhankelijke bediening niet gekeurd. |
| REG-01 | LDB, lokale browser | 65 rijen per resource; 50/15-paginering, zoekmatch buiten pagina één, exacte gefilterde totalen en POST-zoektermen lokaal op 390/1440 px groen. Gepubliceerde herhaling open. |
| REG-02 | LDB, lokale browser | Alle vijf doelgroepen, versieconflict, vreemde editie en doelgroepwijziging lokaal groen; na vertrek uit een bestemming verdwijnt het zonebericht. De duurzame in-appstatus en aparte niet-verzonden capture zijn zichtbaar. Gepubliceerde herhaling open. |
| REG-03 | LDB | Globale pauze blokkeert overgang lokaal; actieve browsers hervatten en actuele keuze open. |
| REG-04 | Open | Duurzame hulp/antwoordcommands aanwezig; privacy en tweede toestel nog uitvoeren. |
| REG-05 | LU | Pure CSV-proeven neutraliseren =,+,-,@ ook na witruimte/control/BOM en escapen quotes. Hosted gate bevat een echte viergezins-download plus participant403; die uitvoering is nog open. |
| REG-06 | LDB | Archiveren/gesloten sibling behoudt bron lokaal; regiepreview/sluiten actieve editie open. |
| REG-07 | LDB | Bedankje vereist eigen bezoek lokaal; herhaling, bewonerszicht en sinkstatus op staging open. |
| SEC-01 | LDB | Geen directe private tabeltoegang, eigen snapshots en Storagepredicate lokaal; REST/realtimecrossactor open. |
| SEC-02 | LDB | Niet-eigen zone/QR en finance geweigerd lokaal; echte API-/Storageverzoeken op staging open. |
| SEC-03 | LDB | Vervalste testflag en legacyreset geweigerd lokaal; volledig historisch/prodautorisatiematrix open. |
| SEC-04 | LDB, LRACE | Anon/onbetaald en refund-versus-scan lokaal; gepubliceerde auth-/capaciteitscheck open. |
| SEC-05 | LU | Geen geheimen nodig voor adaptertests; volledige laatste build/bundle/log/exportscan en stagingbewijs open. |
| SEC-06 | LDB | Tweede volwassene aanvaardt één inschrijving; intrekking blokkeert private receiptreplay lokaal. |
| OFF-01 | LDB | QR-vrijcodepad serverzijdig lokaal; camera-/QRdefect met bereikbare backend op staging open. |
| OFF-02 | LU | Actor-/editiegebonden stale cache lokaal; echte telefoon offline na bestemming open. |
| OFF-03 | LU | Beperkte queue met command-ID/routeversie en digest lokaal; echte offline-reconnectflow open. |
| OFF-04 | LDB, LU | Oude versie/rechten en leaseherstel lokaal; samengestelde offlineconflicten nog uitvoeren. |
| OFF-05 | Open | Coalescing/jitter/backoff aanwezig; meerdere toestellen en gemeten 503/time-outbelasting open. |
| OFF-06 | Open | Vooraf noodinformatie/noodpakket aanwezig; totale uitval en onafhankelijke praktijkwerkwijze open. |
| OFF-07 | LDB | Idempotente ledger/sinkretry lokaal; echte vertraagde outbox/webhookbacklog open. |
| OFF-08 | LU | Cachepartitionering en logoutbeleid lokaal; volledige PWA-heropen/BFCache-actorwissel open. |
| RET-01 | Audit deels | Database/Edge/GitHub geïnventariseerd; daadwerkelijke dedicated VPS-timerinventory gate nog uitvoeren. |
| RET-02 | LDB | Leaseherstel en beschermde bewaartermijn lokaal; werkelijk weekverloop/gerichte onderhoudsproef open. |
| RET-03 | LDB | Expliciete verlopen siblingcleanup bewaart beschermde editie lokaal; stagingcleanup/herstel open. |
| RET-04 | LU | Cache actor/editie/TTL lokaal; opnieuw inloggen en serverherstel op echte browser open. |
| RET-05 | Historisch herstel | Run41433832508 bewijst oude versleutelde restore; nieuwe release/scenariorestore open. |

## Nog afzonderlijk uit te voeren

Geen stagingloadtest of duurtest met onderbouwde piekbegroting is uitgevoerd. Kies vóór belasting aantallen, duur, stopgrenzen en contractprovider binnen een eigen testeditie; meet p50/p95/p99, fouten, databaseverbindingen, capaciteit en sinkvertraging. Geen echte PSP-/mailbelasting. De fysieke Android-/iOS-camera, totale backenduitval met papieren operationeel alternatief, fysieke lokale bakenbediening, werkelijke wandeling en controle van routepaden blijven menselijke praktijkproeven.

Een rij mag pas volledig slagen met datum, gepubliceerde SHA, migratie-/seed/runcontext en geschikt geschoond bewijs. Claim een aanwezige knop, broncode of geslaagde lokale adapter niet als uitgevoerde externe acceptatie. Bewaar oude mislukte resultaten en koppel nieuwe bewijsbestanden aan de laatste relevante bronhash.
