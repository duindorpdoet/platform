# Acceptatiematrix — alle 87 pakketproeven

Peildatum: 3 november 2026, 10:20 UTC; vóór de nieuwe stagingrelease van kandidaat `9b0b215f`. **Geen van deze 87 eindacceptaties is hiermee volledig op de gepubliceerde nieuwe staging-SHA geslaagd verklaard.** Iedere rij houdt de resterende echte proef zichtbaar. De lokale databasebewijzen zijn uitgevoerd in een geïsoleerde PostgreSQL17.6-database; contractadapters zijn geen echte PSP-, cameratoestel-, mail-, straatroute- of hardwareacceptatie.

Bronnen: `05-testen/ACCEPTATIETESTS.md` (82 IDs) en `05-testen/MAANDENLANG-TESTEN.md` (RET-01 t/m RET-05). De lokale titels hieronder verwijzen naar die exacte proeven. Er ontbreken geen IDs en er zijn geen eigen IDs als vervanging toegevoegd.

## Bewijs en geldigheid

| Code | Werkelijk uitgevoerd bewijs | Grens |
|---|---|---|
| LDB | [backend-domain-conflicts-report.json](validation/backend-domain-conflicts-report.json): verse vijfmigratieproef,787assertions en bron-SHA256; [SQL-contracten](../../supabase/tests/127_frightnight_2027_core.sql) | Lokale transacties rollen terug. Het rapport noemt concrete migratie-/testhashes; een latere bronwijziging vraagt nieuwe uitvoering. Geen echte mail/PSP. |
| LRACE | De kern-/provider-/echte engine-concurrencysecties van hetzelfde rapport; [db-concurrency.py](../../scripts/frightnight/db-concurrency.py): twaalf gelijktijdige starts, twee replayrequests, refund/scanrace | Nul overboeking en eenmaal bezoek/award in lokale fixture. Dit is een integriteitsrace, geen stagingpiek-/duurtest of p95/p99-begroting. |
| LU | [security-review-report.json](validation/security-review-report.json) plus genoemde `lib/frightnight/*.test.ts` | Gerichte adapter-/body-/QR-/refundtests; overige modules volgen hun laatste gezamenlijke testuitvoer. Een verwijzing naar aanwezige bron is geen zelfstandig geslaagde browserproef. |
| Audit deels | [ENVIRONMENT-AUDIT.md](ENVIRONMENT-AUDIT.md) en gerichte metadataquery | Read-only audit van bestaande staging. VPS-inventaris en twee echte jobcycli met nieuwe editie zijn aparte releasegates. |
| Historisch herstel | Backup/restore-run41433832508 op ce6bbb52551c4005a24c04fe3a578a4c3860cc18 | Oud herstelbewijs; niet de nieuwe release of een nieuw 2027-scenario. |
| Open / Extern geblokkeerd / Fysiek open | Geen volledig uitgevoerd passend bewijs | Uitvoeren op juiste scope of ontbrekende credential/werkelijk toestel/operationele installatie oplossen. |

De laatste volledige lokale verificatie is groen op exact **`9b0b215f922766f6c69db67dc4f25a37d4a95c9e`**, build **`MsI5gXW47qxHlPk_-YyXo`**: **1565 tests**, zes bestaande optionele integratieskips,17Nodeguards,697clientartifacts, lint/types en productiebuild. De [bronbinding](validation/application-domain-conflicts-verify-report.json) vergelijkt1423bestanden met bevroren prebuildbron, huidige inhoud en Gitcommit, inclusief opgeloste repositorysymlinks. De verse vijfmigratiedatabaseproef telt **787/787** met capaciteit-/provider-/native-engineraces,32afgeschermde tabellen en65functies. De [daadwerkelijke native PostgREST14.5-proef](evidence/local-postgrest14-domain-conflicts/README.md) bewijst dat één oud versieconflict na005één409 geeft, met ongewijzigde beoordeling. Het aanvullende HTTP-enginelogexperiment blijft afzonderlijk failed/onbewezen; de native SQL-tweetransactieproef is wel geslaagd. De exacte nieuwe [CI41612954081](validation/ci-9b0b215f-report.json) is volledig groen: drie jobs,137pgTAPbestanden/4661assertions en24browsertests; geen verplichte skip of mailwaiver. De normale stagingrelease41615887268 heeft005en behoud268tabellen doorlopen, maar stopte vóór apppublicatie op VPS-ENOSPC; ook de inspectjob kon geen logbestand openen. Geen account-/Storage-/load-/RET05proef gestart in die run. Zie [herstelgrens](STAGING-DISK-HERSTEL.md).

Het eerdere lokale UI-bewijs op **hanzA2t5Xaby269LUnhWK** blijft met eigen build-/broncontext behouden: [24publieke +10nativeoffline +27accountchecks](evidence/feedback-closure-offline-assets/README.md). De extra lokale accountguard blokkeerde33openbare kaartachtergrondrequests; deze passage bewijst geen geleverde kaartachtergrond. Eerdere42providergrens-UIchecks hebben expliciet nul externe fetchpogingen. De aanvullende echte mailpolicy-, offline-/sessie- en bewonersproeven staan hieronder bij de betreffende IDs. Werkelijke wederzijdse foto-upload/download via StorageHTTP en de gepubliceerde125-clientbelasting blijven nieuwe releasegates.

De vorige build **fzribBblz0y5tNosd_-R-** heeft **96 geslaagde lokale browserchecks**: 23 publieke, 24 download-/klok-/privacy-, 27 aanvullende scenario-, 12 HUI-02- en 10 spel-/bakencontroles. Die tussenbuild voegde uitsluitend een zichtbare regiefotolink toe; de gerichte browserherproef slaagt voor 23 publieke, 12 HUI-02- en 12 fotolinkpresentatiechecks met eigen buildbewijs. De fotolinkfixture bewijst geen Storage HTTP. De eerdere passage op **5AlZTx-My0ydPqjQnmPQY** behoudt haar 24 uitkomsten en broncontext. Eerdere contact-, quote- en regieproeven blijven eveneens met hun oorspronkelijke builds herkenbaar.

De hosted scripts zijn uitsluitend na geverifieerde binding, backup/restore, behoud en deployment toegestaan. Zij gebruiken de werkelijk gepubliceerde SHA en een eigen nieuwe testscope. Geen lokale uitkomst vervangt een externe PSP-, echte camera-, fysieke straat-/baken- of gepubliceerde duurproef.

De [gedetailleerde beoordeling van alle 87 IDs](validation/acceptance-evidence-assessment.json) koppelt bovendien elke proef aan de werkelijk uitgevoerde lokale SQL-, unit-, race- en browseruitkomsten, actuele bronhashen en precieze resterende proeven. Zij bevat geen gepubliceerde succesclaim. De nieuwste lokale aanvullingen omvatten acht loginchecks, zeven activiteit-/pauze-/finalechecks en zes samenloop-UIchecks; inschrijffixtures worden daarbij expliciet meegeteld.

## Registratie per pakket-ID

Alle rijen hebben eindstatus **open op nieuwe staging**. De bewijskolom beschrijft uitsluitend het werkelijk aanwezige lokale deelbewijs en de noodzakelijke aanvulling. `Extern geblokkeerd` betekent geen bewezen PSP-test omdat de stagingsecretnaam `MOLLIE_TEST_API_KEY` bij controle ontbrak. Er wordt geen OTP aangevraagd om een vakje groen te maken.

| ID | Lokale bewijssoort | Deelbewijs en resterende acceptatie |
|---|---|---|
| ENV-01 | LDB | Sink heeft geen ontvangerkolom; synthetische gezinnen zonder oud huishouden. Hosted sink- en bezorgcontrole open. |
| ENV-02 | LDB, LU | Nieuwe payment/sinktabellen en retry raken geen legacy-outbox. Echte providerlink/refund nog open. |
| ENV-03 | Open | Croncatalogus geaudit; twee echte cycli plus nieuwe editie observeren na release. |
| ENV-04 | LU, echte lokale runtime | [Drie daadwerkelijke handlerproeven](evidence/local-final-mail-policy/report.json) op ongewijzigde hanz-app: ontbrekend en allowlist blijven exact één duurzame sink na retry; ongeldige liveconfig geeft422 vóór mutatie. Effectieve policy na Nextinitialisatie, nul legacy-outboxeffect,54 uitsluitend lokale fetches/nul externe pogingen en eigen cleanup bewezen. Geen foutconfig op gepubliceerde staging toegepast. |
| ENV-05 | LDB | Lokale legacy-aantallen en bewaarde dummyhistorie gelijk. Echte stagingbehoudsvergelijking opnieuw vereist. |
| INS-01 | LDB, lokale browser | Echte vierpersoonsinschrijving, serverquote en identiek commandreplay lokaal bewezen. Gepubliceerde herhaling blijft open. |
| INS-02 | LDB, lokale browser | Consent-/databasegrenzen lokaal; acht echte loginchecks op390/1440 weigeren lege/foutieve e-mail vóór Auth met native feedback en nul OTP/POST. Directe Auth/API-invalidemail en gepubliceerde herhaling blijven apart. |
| INS-03 | Extern geblokkeerd | MOLLIE_TEST_API_KEY ontbreekt in stagingsecretnamen. Contractbetaling is afzonderlijk gelabeld. |
| INS-04 | LDB | Onbetaald starten geweigerd; return-URL zonder betaling nog via gepubliceerde app uitvoeren. |
| INS-05 | LU | Adapter valideert statusvormen; echte PSP mislukken/open/annuleren/verlopen niet uitgevoerd. |
| INS-06 | LDB, LU | Dubbele/out-of-order providerbevestiging zonder dubbele ledger lokaal; vijf echte webhookreplays open. |
| INS-07 | LDB | Holds, verlopen hold, late betaling en herboeken lokaal. Gelijktijdige laatste startplaatsen op staging open. |
| INS-08 | LDB, lokale browser | Eigen contactwijziging, tweede tab en stale conflict lokaal groen; voorkeuren/herboeken lokaal getoetst. Gepubliceerde contact-/startwijziging en tweede toestel open. |
| INS-09 | LDB, lokale browser | Vanaf eerste betaalpoging staan personen/tocht/bedrag vast, ook na failed/expired of tariefwijziging; duidelijke organisatie-uitleg en gemanipuleerd verzoek409 lokaal bewezen. Start/contact/comfort blijven werken; refund wordt niet heractiveerd. Gepubliceerde herhaling open. |
| INS-10 | LDB, LRACE, LU | Refundledger/scanrace en providerbindings lokaal; echte PSP-testrefund niet uitgevoerd. |
| QR-01 | Fysiek open | Geen echte Android-/iOS-cameratest uitgevoerd. HTTPS-camera-implementatie is geen toestelbewijs. |
| QR-02 | LDB, native lokale browser | Native Chromiumpermission denied/NotAllowedError met virtueel device; zichtbare hersteltekst en dezelfde handmatige code-UI geeft één serverbestemming. Geen fysieke camera-/optische scanclaim; stagingherhaling open. |
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
| ROU-02 | LDB, lokale browser | Actieve gedeelde UI verlaagt2→1 en vermijdt rook/flitsen; serverunion telt zes personen, vervangt bestemming door geschikt regulier niveau1 en bewaart eigen quotes/voorkeur. Gepubliceerde en fysieke wandeling open. |
| ROU-03 | LDB, lokale browser | Eigenaar pauzeert werkelijke huidige gewone bestemming via UI: oude QR409 zonder bezoek/award, herstelUI geeft één alternatief. Gepubliceerde herhaling open. |
| ROU-04 | LRACE | Elf van twaalf gezinnen wachten veilig bij volle passende zones lokaal; UI-uitleg staging open. |
| ROU-05 | LDB, LRACE | Twaalf starts tegelijk, nul overboeking lokaal; herhalen op geverifieerde stagingeditie open. |
| ROU-06 | LDB | Verlopen lease vereist hervatten; precies één herstelde bestemming. Stagingherhaling open. |
| ROU-07 | LDB, LRACE, lokale browser | Bewonerswaarneming en appclaims tellen bekende personen éénmaal; extra bezoekers, verouderde waarneming, expliciete leegbevestiging en vijf echte races lokaal bewezen. Nieuwe stagingherhaling open. |
| ROU-08 | Open | Loop-/bezoek-/sluitmarge in deterministische selectie; specifieke grensproef nog uitvoeren. |
| ROU-09 | Open | Skipcommand aanwezig; oude QR zonder award en terugtoewijzing nog expliciet testen. |
| ROU-10 | LDB | Venstereinde/herstel naar Duinpad lokaal; gemeten verre locatie en wandelmarge open. |
| ROU-11 | Open | Volle/gesloten finale met hulp- en herstelpad nog specifiek accepteren. |
| ROU-12 | LDB, lokale browser | Alle vier gewone zones werkelijk gesloten; beide gekoppelde gezinnen krijgen één Duinpadfinale met nul quests. Pas de echte finale-scan rondt af. Gepubliceerde herhaling open. |
| ROU-13 | LDB | Stoppen geeft één Duinpadbestemming; rustige/stepvrije fysieke terugkeer open. |
| SAM-01 | LDB, lokale browser | A maakt zichtbaar een uitnodiging; B voert code + instemming in en accepteert. Beide onafhankelijke UIs tonen herkenbare leden en dezelfde actuele bestemming. Geen fysiek tweede toestel; stagingherhaling open. |
| SAM-02 | Open | Serverregels aanwezig; alle drie afwijzingsvarianten nog met bewijs uitvoeren. |
| SAM-03 | LDB | Vier gezamenlijke personen en strengste voorkeuren lokaal; exact vier-plus-vijfscenario open. |
| SAM-04 | LDB, lokale browser | Niet-uitnodiger B voltooit via echte handmatige QR-UI aantoonbaar met200 de gedeelde bestemming. Beide krijgen precies één persoonlijk bezoek/award en blijven coherent. Gepubliceerde herhaling open. |
| SAM-05 | LRACE | Receipt-replayrace lokaal; herhaalde gelijktijdige scans van verschillende samenloople­ den open. |
| SAM-06 | LDB, lokale browser | Beide gezinnen hebben vóór aansluiten één verschillend werkelijk bezoek. Na expliciete UI-instemming delen zij één bestemming; persoonlijke oude bezoeken/awards blijven exact gelijk, zonder cadeauhistorie. Gepubliceerde herhaling open. |
| SAM-07 | LDB, lokale browser, LRACE | B verlaat via echte UI; twee zelfstandige IDs, elk één actuele claim en eigen ongewijzigde historie/ledenlijst. De verplichte herhaalde leave-versus-scanraces op staging blijven apart open. |
| SAM-08 | Open | Eventlock/versies en voorkeuraggregatie aanwezig; join-versus-voorkeurswijzigingrace open. |
| SAM-09 | Open | Afgeronde/actieve combinatie nog specifiek uitvoeren en geschiedenis vergelijken. |
| HUI-01 | LDB, LU | Eigen aanvraag, geverifieerd contact/ligging en Storagepredicate lokaal; echte upload/browserflow open. |
| HUI-02 | LDB | Versiegebonden wijzigingsverzoek/afwijzing met private reden, herindienen en expliciete locatieherbevestiging vóór goedkeuring lokaal bewezen. De echte lokale regie-/bewoners-UIflow slaagt voor 12 controles op de actuele build; nieuwe stagingherhaling blijft vereist. |
| HUI-03 | LDB, echte lokale browser/API | [Nieuwe geïntegreerde proef](evidence/local-final-owner-coverage/report.json): echte eigenaar wijzigt type/intensiteit/effecten/uren/capaciteit terwijl gezin onderweg is; nieuwe beoordeling/ligging vereist, oude scan409 zonder bezoek/award, zichtbare hervatknop geeft één geschikte gewone bestemming. Vijf ongeldige varianten geweigerd; candyintensiteit serverzijdig0. Geen hostedclaim. |
| HUI-04 | LDB | Pauze, vroege afloop en geen heropening buiten uren lokaal bewezen; echte browserherhaling open. |
| HUI-05 | LU | Uitgegeven QR-exportreceipt lokaal; afdruk en echte camerascan van fysiek bord open. |
| ACT-01 | LDB, lokale browser/APIrace | Twee zelfstandige gezinnen van4/2 racen om vier hele-gezinplaatsen:200/409, geen overboeking; onafhankelijke context leest exact dezelfde duurzame boeking. Gepubliceerde herhaling open. |
| ACT-02 | LDB, lokale browser | Werkelijke annulering/replay geeft eenmaal plaatsen vrij, herboeken en toegewezen medewerker checkt via UI precies vier personen in. Onbevoegde eigenaar, vreemde activiteit en ingetrokken medewerker403. Gepubliceerde herhaling open. |
| KID-01 | LDB, lokale browser | Alle drie raadsels en drie spelinterfaces werkelijk bediend met fout/herkansing op actuele build; gepubliceerde herhaling open. |
| KID-02 | LDB, lokale browser | Alle zes voltooide spellen blijven na refresh en tweede onafhankelijke browsercontext bewaard; zes echte commandreplays geven geen dubbele award. Fysiek tweede toestel/gepubliceerde herhaling open. |
| KID-03 | LDB, lokale browser | Nieuwe echte hanz-EDGEproef weigert onbekende quest, verzonnen awardcommand en verborgen finalemanipulatie zonder award. Gepubliceerde herhaling blijft nodig. |
| BAK-01 | LU | Stagingbakenadapter ondersteunt rehearsal zonder hardware; geen fysiek lichtbewijs. |
| BAK-02 | LDB | Finalescan en digitale bakenaward na enkele huizen lokaal; drie UIstappen/Nachtpas op staging open. |
| BAK-03 | LU, netwerkloze container | Ongewijzigde stagingadapter werkelijk uitgevoerd zonder netwerk en met alleen-lezen bron: stabiele rehearsal/finale/faultreceipt, simulated=true en hardwareEnabled=false. Geen fysieke hardwarekeuring. |
| REG-01 | LDB, lokale browser | 65 rijen per resource; 50/15-paginering, zoekmatch buiten pagina één, exacte gefilterde totalen en POST-zoektermen lokaal op 390/1440 px groen. Gepubliceerde herhaling open. |
| REG-02 | LDB, lokale browser | Alle vijf doelgroepen, versieconflict, vreemde editie en doelgroepwijziging lokaal groen; na vertrek uit een bestemming verdwijnt het zonebericht. De duurzame in-appstatus en aparte niet-verzonden capture zijn zichtbaar. Gepubliceerde herhaling open. |
| REG-03 | LDB, lokale browser | Globale pauze via regieUI weigert geldige scan409 EVENT_PAUSED en schakelt scanUI uit. Hervatten hercontroleert één bestemming zonder cadeauvoortgang. Gepubliceerde herhaling open. |
| REG-04 | Open | Duurzame hulp/antwoordcommands aanwezig; privacy en tweede toestel nog uitvoeren. |
| REG-05 | LU | Pure CSV-proeven neutraliseren =,+,-,@ ook na witruimte/control/BOM en escapen quotes. Hosted gate bevat een echte viergezins-download plus participant403; die uitvoering is nog open. |
| REG-06 | LDB, lokale browser | Nieuwe regieformulieren sluiten daadwerkelijk tijdens globale pauze; bestaande loper scant de finale, nieuwe instroom blijft dicht. Oude close-replay wist geen latere pauze; gesloten-pauzehervatting werkt. Gepubliceerde herhaling open. |
| REG-07 | LDB, lokale browser | Nieuwe afzonderlijke algemene bedankfunctie via gedeelde volwassene werkelijk bediend; één record/receipt, eigenhuisbezoek/replay,500-tekengrens en private regie-inbox bewezen. Na intrekking geen nieuw of herhaald command. Algemene evaluatie gold eerder ten onrechte als algemeen bedankje; dat is gericht gecorrigeerd. Geen externe dankmail. Gepubliceerde herhaling open. |
| SEC-01 | LDB | Geen directe private tabeltoegang, eigen snapshots en Storagepredicate lokaal; REST/realtimecrossactor open. |
| SEC-02 | LDB, echte lokale browser/API | [Twee echte afzonderlijke bewoners](evidence/local-final-owner-coverage/report.json) proberen wederzijds zone.status/zone.apply en payments.list: zes403, eigenUI/snapshotonly, beide zonerijen en voortgang gelijk. Werkelijke wederzijdse StorageHTTP blijft onderdeel van de gepubliceerde parentgate. |
| SEC-03 | LDB | Vervalste testflag en legacyreset geweigerd lokaal; volledig historisch/prodautorisatiematrix open. |
| SEC-04 | LDB, LRACE | Anon/onbetaald en refund-versus-scan lokaal; gepubliceerde auth-/capaciteitscheck open. |
| SEC-05 | LU | Geen geheimen nodig voor adaptertests; volledige laatste build/bundle/log/exportscan en stagingbewijs open. |
| SEC-06 | LDB | Tweede volwassene aanvaardt één inschrijving; intrekking blokkeert private receiptreplay lokaal. |
| OFF-01 | LDB | QR-vrijcodepad serverzijdig lokaal; camera-/QRdefect met bereikbare backend op staging open. |
| OFF-02 | LU | Actor-/editiegebonden stale cache lokaal; echte telefoon offline na bestemming open. |
| OFF-03 | LU | Beperkte queue met command-ID/routeversie en digest lokaal; echte offline-reconnectflow open. |
| OFF-04 | LDB, LU, echte lokale browser | [Nieuw geïntegreerd bewijs](evidence/local-final-offline-coverage/report.json): echte offline visitqueue, intussen eigen contractrefund of tweedevolwassene-intrekking in andere context, reconnect403 zonder bezoek/award/nieuwe bestemming; ingetrokken gegevens verdwijnen na herladen. hanz/d843bronbinding, geen hosted claim. |
| OFF-05 | Open | Coalescing/jitter/backoff aanwezig; meerdere toestellen en gemeten 503/time-outbelasting open. |
| OFF-06 | Open | Vooraf noodinformatie/noodpakket aanwezig; totale uitval en onafhankelijke praktijkwerkwijze open. |
| OFF-07 | LDB | Idempotente ledger/sinkretry lokaal; echte vertraagde outbox/webhookbacklog open. |
| OFF-08 | LU, echte lokale browser | [Nieuwe persistent-browserproef](evidence/local-final-offline-coverage/report.json): werkelijk sluiten/offlineheropenen geeft private503/no-store; echte eigen GoTrue-refresh herstelt dezelfde route zonder nieuwe award. CacheStorage bevat geen private response; logout en nieuwe identiteit wissen/scheiden oude data. Geen fysieke mobiele PWAclaim. |
| RET-01 | Audit deels | Database/Edge/GitHub geïnventariseerd; daadwerkelijke dedicated VPS-timerinventory gate nog uitvoeren. |
| RET-02 | LDB | Leaseherstel en beschermde bewaartermijn lokaal; werkelijk weekverloop/gerichte onderhoudsproef open. |
| RET-03 | LDB | Expliciete verlopen siblingcleanup bewaart beschermde editie lokaal; stagingcleanup/herstel open. |
| RET-04 | LU, echte lokale browser | [12/12 nieuwe geïntegreerde proeven](evidence/local-final-offline-coverage/report.json) omvatten30min-actorcache, echt logout, volledig browserherstart, verse loginidentiteit en eigen sessievernieuwing. Eigen drie nieuwe lokale Authactors retired/behouden, geen gedeelde persona gewijzigd; geen hosted duurclaim. |
| RET-05 | Historisch herstel | Run41433832508 bewijst oude versleutelde restore; nieuwe release/scenariorestore open. |

## Nog afzonderlijk uit te voeren

Geen stagingloadtest of duurtest met onderbouwde piekbegroting is uitgevoerd. Kies vóór belasting aantallen, duur, stopgrenzen en contractprovider binnen een eigen testeditie; meet p50/p95/p99, fouten, databaseverbindingen, capaciteit en sinkvertraging. Geen echte PSP-/mailbelasting. De fysieke Android-/iOS-camera, totale backenduitval met papieren operationeel alternatief, fysieke lokale bakenbediening, werkelijke wandeling en controle van routepaden blijven menselijke praktijkproeven.

Een rij mag pas volledig slagen met datum, gepubliceerde SHA, migratie-/seed/runcontext en geschikt geschoond bewijs. Claim een aanwezige knop, broncode of geslaagde lokale adapter niet als uitgevoerde externe acceptatie. Bewaar oude mislukte resultaten en koppel nieuwe bewijsbestanden aan de laatste relevante bronhash.

De werkelijke tussenrelease **3fc360b2** heeft backup/herstel267 tabellen/12Storageobjecten, behoud, deployment, Auth/sink en publieke24 doorlopen. De extra offlinebeeldproef vond een niet-bediend precachelogo; de aangescherpte hanz-proef slaagt na de gerichte fix. Parent stopte op een onjuiste canonieke negatieve fixture, met geslaagde eigen cleanup. Dat is vervangen door een werkelijk onbevoegde private editie, inclusief onveranderde ondertekende context. Load en RET05 zijn in die tussenrun niet uitgevoerd. Daarna zijn5cc en d843 als tussenrelease werkelijk gepubliceerd. Hun publieke proeven slaagden, maar de parentproeven stopten respectievelijk op een cacheheaderfixture en het concrete PostgREST14-conflictretryprobleem. Beide eerste uitkomsten en veilige cleanup blijven bewaard. De nieuwe9b-kandidaat vereist opnieuw alle exacte CI-/release-/account-/belasting-/herstelgates; geen blanket87/87-claim.
