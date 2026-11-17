# FrightNight 2027 — uitvoeringsstatus

Peildatum: **3 november 2026, 10:27 UTC**. De eindrelease is **nog niet geaccepteerd**. De normale stagingstraat stopte op een volle VPS-schijf tijdens het kopiëren van dependencies. Ook de onderhoudsrunner kon daarna zijn eigen logbestand niet openen. Een bestaand VPS-console-/SSH-beheerkanaal is gevraagd; er is nog geen bruikbare toegang ontvangen en er is niets opgeruimd.

## Actuele binding en publicatie

| Onderdeel | Werkelijk vastgestelde toestand |
|---|---|
| URL | https://staging-halloween.duindorpdoet.nl |
| Gepubliceerde runtime | `d8439e09c67083548d8b09ac4110d24820a52dd0` |
| Bestaand immutable pad | `/srv/sites/duindorphalloweenstg/releases/d8439e09c670-41607150306-1` |
| Nieuwe runtimekandidaat en stagingbranch | `9b0b215f922766f6c69db67dc4f25a37d4a95c9e` |
| Effectieve database | `staging-halloween`, ref `nocteiuvohesvqbowchw`, schema `api` met private `app_private`-tabellen |
| GitHub environment / VPS-site | `staging` / `duindorphalloweenstg` |
| Dedicated runner | `dg-sites-vps-01-duindorphalloweenstg-01` |
| Editie / merk / betaalprovider | `frightnight-2027-test` / `frightnight-2027-v7` / zichtbaar `contract` |
| Main en productie | Ongewijzigd `ce6bbb52551c4005a24c04fe3a578a4c3860cc18`, opnieuw gecontroleerd om10:25UTC |
| Bewijs en documentatie | Featurebranch `codex/frightnight-2027-staging`, [draft-PR73](https://github.com/duindorpdoet/platform/pull/73); deze PR bevat uitsluitend documentatie/bewijs ten opzichte van staging9b |

De onafhankelijke laatste [healthmeting](validation/published-health-report.json) geeft HTTP200/ok op d843. Dit bewijst geen volledige productgezondheid bij een volle schijf. Het historische project `dtubngvxfbupgvgfrjko` is geen target. Er is niet naar productie gedeployd.

## Groen op exact kandidaat9b

- De volledige [CI41612954081](https://github.com/duindorpdoet/platform/actions/runs/41612954081) en de onafhankelijke normale staging-push-[CI41615887239](https://github.com/duindorpdoet/platform/actions/runs/41615887239) zijn completed/success. In beide: drie jobs en alle verplichte stappen success, **1565 tests met zes bestaande optionele skips,17 Nodeguards,697 clientartifacts,24 native browserchecks en4661 pgTAP-asserties/137 bestanden**. Geen verplichte skip of mailwaiver. [Eerste rapport](validation/ci-9b0b215f-report.json), [herhaalrapport](validation/ci-9b0b215f-staging-repeat-report.json).
- De volledige lokale `VITEST_MAX_WORKERS=2 FRIGHTNIGHT_BUILD_NO_CACHE=true pnpm verify` is eveneens groen, build `MsI5gXW47qxHlPk_-YyXo`. **1423 bronbestanden**, inclusief opgeloste repositorysymlinks, zijn aan de bevroren prebuildbron, huidige inhoud en Gitcommit9b gebonden. [Verificatie en bronhashen](validation/application-domain-conflicts-verify-report.json). Het ruwe uitvoerlog wordt bytegelijk bewaard; de LF-genormaliseerde hash staat afzonderlijk vermeld.
- De verse geïsoleerde vijfmigratiedatabase bewijst **787/787** nieuwe kerncontracten, twaalf gelijktijdige capaciteitsraces, vijf providerraces en een echte tweetransactie-40001 door de publieke wrapper. [Backendrapport](validation/backend-domain-conflicts-report.json).
- Een daadwerkelijke native PostgREST14.5-proef bewijst het concrete stale-reviewprobleem vóór/na005: zes transactieaanvangspogingen tot de uitsluitend lokale veiligheidslimiet, daarna **één409/PT409 met behoud van versie4**; actuele goedkeuring werkt. De aanvullende HTTP-enginelogcontrole blijft expliciet failed/onbewezen; de echte native SQL-tweetransactieproef bepaalt die dekking. [Dossier met alle eerste uitkomsten en cleanup](evidence/local-postgrest14-domain-conflicts/README.md).
- De nieuwe versleutelde backup/herstelproef van release41615887268 is groen: **268 tabelfingerprints en12 Storage-objecten exact hersteld**, inclusief de exacte005-dryrun. Artifact **13221915863**,33926789bytes, digest`823b8d6b44122130ea8f0f6eb828d11d3616bfccda34eee51c9a4c99a5ac1fab`, beschikbaar tot **3december2026om10:07:19UTC**. [Backupbewijs](validation/pre-migration-backup-9b0b215f-report.json), [artifact](https://github.com/duindorpdoet/platform/actions/runs/41615887268/artifacts/13221915863).
- De onafhankelijke post005-metadata bevestigt **32/32 RLS-tabellen,65 functies,vier authenticated actor-RPCs**, zeven extern onuitvoerbare private transportimplementaties en veilige SECURITY DEFINER-search_paths. Alle15 nieuwe API/private body- en definitiehashen zijn gelijk aan de verse lokale vijfmigratiedatabase. Geen directe anon/auth/service-tabelrechten of onverwachte EXECUTE-grants. [Databasebewijs](validation/post005-database-metadata-9b0b215f-report.json).

CI- en lokaal bewijs vervangen geen gepubliceerde account-, Storage-, belasting-, scenarioherstel- of fysieke praktijkproef.

## Waar de laatste stagingstraat stopte

Normale push-[release41615887268](https://github.com/duindorpdoet/platform/actions/runs/41615887268), deployjob125851451038, heeft appvalidatie, verse backup/herstel, gecontroleerde historie/preflight,005-toepassing en behoudsvergelijking werkelijk uitgevoerd. Alle268bestaande tabellen zijn behouden; precies één nieuwe migratieversie20261103092502 en drie natuurlijke cronhistorierijen kwamen erbij. Nul nieuwe mailevents of reconciliatiefouten. De32-tabellenveiligheid, timerinventaris, Auth/sink-before-seed, Danny-bootstrap en idempotente initialisatie zijn geslaagd; `seeded=false`, seedVersion1.

Daarna stopte `dg-site-deploy` op **ERR_PNPM_ENOSPC** bij dependencykopie naar `/srv/sites/duindorphalloweenstg/releases/9b0b215f9227-41615887268-1`, vóór apppublicatie. De daaropvolgende inspect-onlyrun41617415557 crashte voordat `df`/`du` werd uitgevoerd, met `System.IO.IOException: No space left on device` bij zijn eigen runnerlog. Er is nog niet vastgesteld of bytes, inodes of beide ontbreken. Geen cleanup of nieuwe deployretry uitgevoerd. [Afgebakend foutbewijs](validation/staging-9b0b215f-deploy-failure.json), [beperkte herstelroute](STAGING-DISK-HERSTEL.md).

Account-/Storage-/REG-/EDGE-,125-clientload- en RET05-jobs zijn in deze poging **niet gestart**. Er zijn geen nieuwe accountfixtures, automatische OTP, externe PSP-betalingen, transactionele mail- of pushbezorgingen vanuit deze poging gemaakt. De definitieve32-tabellenobservatie na alle writes is eveneens nog niet gestart.

## Fase0 — inventaris, afscherming en behoud

Het volledige overdrachtspakket is gedownload, uitgepakt en gelezen;49/49 bestanden en hashes zijn geverifieerd. Bron: `/home/codex/frightnight-input-20261103/Duindorp-FrightNight-2027-Codex-Overdracht`. De oorspronkelijke werkboom met lokale onderzoeken is behouden. De bouw staat in `/home/codex/repos/duindorphalloween-frightnight-2027`, remote `duindorpdoet/platform`.

GitHub environment, effectieve URL/ref, dedicated runner en staging-VPS-site zijn gezamenlijk bevestigd. De13 bekende staginghotfixes worden via de bestaande hashgecontroleerde reconciliatie bewezen; geen lege migraties of blind include-all. Nieuwe operationele data staat uitsluitend in private editiegebonden `fn_*`-tabellen achter beperkte `api.frightnight_*`-RPCs. Rollen komen uit databasecapabilities.

De bestaande jobs45/81/184 voor route-dispatch, poortkamer en legacy-mail blijven actief en ongewijzigd. Nieuwe2027betalingen raken geen legacyhouseholds/payment_requests/outbox. Nieuwe transactionele mail blijft een aparte editie-/rungebonden capture zonder externe ontvanger. Auth heeft een afzonderlijke server-only allowlist met drie toegestane echte ontvangers, inclusief het geverifieerde bestaande Danny-account. Hook en hashgate zijn vóór bootstrap/seed actief; geen automatische OTP aangevraagd.

De werkelijke VPS-inventaris vond16systemtimers en16systemcronbestanden, nul onbekende scopedhashes. Database-/Edge-/GitHub-retentie en onderhoud zijn geïnventariseerd. Onleesbare root-/andere-user-/externe timers blijven een expliciete waarnemingsgrens. Geen sudo, productiecache-opruiming, algemene cronstop of mailuitschakeling als vervanging voor editie-isolatie.

## Fase1–3 — gebouwde software

De bron bevat één definitieve donkerev7 met echte pakketbeelden/fonts, Pompoenkoning, Kraaienbode en rustige weergave, overgezet naar de bestaande Next.js App Router-app. Next16.3.5/React19.3.0/TS5.9.3 zijn behouden; Motion14.6.0 is vastgezet. De publieke shell en beelden hebben geen zware live-RPCafhankelijkheid.

Serverwerking omvat registratie/prijs/startblokken, providerclaims en contract-/Mollie-testadapter, deterministische atomaire route-/capaciteitsclaims, camera/handmatige QR, replay-/leaseherstel en Duinpadfinale; vrijwillige samenloop, activiteiten, drie raadsels en drie pleinspellen, Lichtvonken/zegels, duurzame meldingen, hulp en bedankjes. Bewoners hebben eigen aanvraag/contact/ligging/beoordeling, comfort/capaciteit, private foto's, status/waarneming en QR-borden. Regie heeft begrensde lijsten, bevoegdheden, betalingen, berichten, livebeleid, afsluiting, exports/audit en testbeheer. Er is geen vrij te kiezen administratieve rol of lokaal betaal-/routegezag.

Het testcentrum gebruikt expliciete editie/run, synthetische seeds, klok/scenario's, begrensde reset en365echte dagen bescherming zonder nieuwe automatische delete-/afsluitjob. Een contractsandbox wordt vóór seed/inschrijving voor precies één eigen lege run bevestigd. Reset bewaart echte testerreizen, Auth, financiële ledger en audit; voor een volledig nieuwe echte gezinsreis maak je een nieuwe configuratiekopie.

Privéofflinecache is actor-/editiegebonden, maximaal30minuten en wordt bij logout/identiteitswissel gewist. De beperkte commandqueue bevestigt geen autoritatieve offlinebetaling, scan of nieuwe bestemming. Er zijn een vooraf downloadbaar noodpakket, publieke offlinehulp en papieren operationele instructies. De stagingbakenadapter is netwerkloos en heeft geen hardware-uitgang. PDOK-/wandelproviders zijn server-side begrensd/gecachet met fallback. Zie [beheerhandleiding](BEHEERHANDLEIDING.md) en [servercontract](BACKEND-CONTRACT.md).

`MOLLIE_TEST_API_KEY` ontbreekt. De volledige adapter en contracttests zijn aanwezig; de zichtbare contractmodus is **geen bewezen externe Molliebetaling/refund**. Live betalen staat uit. Providerbinding voorkomt dat latere globale Mollieconfiguratie bulkproeven naar een echte PSP stuurt. Menselijke mailboxontvangst, echte Android-/iOS-camera, fysieke straatpaden, papieren noodoefening en lokaal baken vereisen afzonderlijk werkelijk praktijkbewijs.

## Toegepaste migraties — alle vijf onveranderlijk

005 is op3november2026om10:11:13UTC via de normale stagingstraat toegepast. Een aanvullende correctie vereist een nieuwe forward-only migratie.

| Migratie | SHA256 |
|---|---|
| `20261103012453_frightnight_2027_isolated_core.sql` | `5f346ce7afb8ef6bf32a783a66e974d1e1a3c44a6194a13d1f65228c98468ac6` |
| `20261103042000_frightnight_2027_edition_access.sql` | `d9a29c60ec507575bf99199f0c60d9444e5223a479f71620305223e323b3e627` |
| `20261103071355_frightnight_2027_payment_sandbox.sql` | `fb5144da995ebb92f448cf4195cc42fc7e5626378b1accf034681df6741e6ed4` |
| `20261103073433_frightnight_2027_feedback_closure.sql` | `452bf8c7e4a5a75b80f9db9b481d370251f01505d85e0c5052eb7cf1109e4dd8` |
| `20261103092502_frightnight_2027_domain_conflicts.sql` | `f4ab3b236c4a5e9066e335ab45ad28e7f33d6ad47481f484e5671faafde98570` |

## Fase4 — browserbewijs en resterende acceptatie

De daadwerkelijke gepubliceerde publieke proef op **d843** is24/24plus19/19, met tien volledig geladen en visueel beoordeelde390/1440-beelden. Native serviceworkercontroller, offline-logo, private503/no-store, cacheopschoning en reconnect zijn bewezen; nul Auth-/mutatie-/externe requests. [D843-bewijs](evidence/public-hosted-d8439e09/README.md). Dit zijn geen9b-beelden.

De eerdere d843-accountproef stopte op `HUI02_STALE_REVIEW_ACCEPTED`, na vijf geslaagde blokken inclusief echte private200-mailpreview, activiteiten en zes quests. Read-only diagnose bewijst nul goedkeuringscommits en acht exacte lokale/remote functiehashen; de concrete oorzaak was PostgREST14.5 dat bedoelde40001-conflicten bleef herhalen.005 corrigeert die transportgrens. Alle eigen cleanup van die poging is geslaagd. De oude foutlus was om09:25:50UTC aantoonbaar verdwenen; geen terminate, herstart of cronstop uitgevoerd. [Diagnose](POSTGREST-COMPATIBILITY.md).

Lokale complete browser- en aanvullende mailpolicy-/offline-/sessie-/bewonersproeven blijven bewaard met hun echte build- en broncontext. Onder meer ENV04, OFF04/OFF08/RET04 en SEC02/HUI03 hebben nieuwe geïntegreerde bewijzen. [Bewijsindex](evidence/README.md), [beeldselectie en grenzen](validation/local-handoff-visual-review.json). De87pakket-IDs en hun resterende proeven staan volledig in de [acceptatiematrix](ACCEPTANCE-MATRIX.md); er is geen blanket87/87-claim.

De werkelijke keyless PDOK-/OSRM-adapterproef bewijst drie GETs, BAG-filtering,31wandelpunten/624,9m/negen minuten en cachecoalescing. Geen fysieke straat-, VPS-provider- of24uurscacheclaim. [Providerbewijs](validation/provider-adapters-real/report.json).

## Fase5 — herstel, release en overdracht die nog moeten volgen

1. Het bestaande VPS-console-/SSH-beheerkanaal beschikbaar krijgen; vrije bytes/inodes en uitsluitend staging-eigen herbouwbare caches inspecteren en gericht ruimte herstellen. Geen productieonderhoud, releases/backups of databasehistorie verwijderen. [Concreet hersteloverzicht](STAGING-DISK-HERSTEL.md).
2. Nieuwe normale release op exact9b, met verse versleutelde backup/herstel, preflight, behoud en `dg-site-deploy`; alle vijf migraties blijven ongewijzigd. Beide exacteCI-runs zijn groen.
3. De werkelijk gepubliceerde SHA/immutable pad/health controleren; volledige account-, wederzijdse StorageHTTP-, REG- en EDGEproeven inclusief eigen cleanup uitvoeren.
4. Begrensde stagingbelasting12/25/50/100/125clients en membershipraces, daarna verse versleutelde32-tabellen-RET05-scenariorestore.
5. Na alle writes/cleanup twee nieuwe natuurlijke succesvolle cycli van elk job45/81/184 observeren: inhoud/counts van alle32FrightNight-tabellen en legacy-outbox gelijk. Geen handmatige jobaanroep of globale uitschakeling.
6. Pas daarna definitieve gepubliceerde screenshots, rollen/inloginstructies, testrapport en eerste volledig geaccepteerde compatibele rollbackrelease vastleggen. Externe configuratie en niet-uitgevoerde praktijkproeven herkenbaar open laten.

De pre-migratiebackup vervangt RET05 niet. Apps0ddd/3fc zijn na003 niet betaalcompatibel; d843/5cc missen de volledige veilige algemene PT409-afhandeling uit005/9b. De oude ce6-Poortenshell is geen2027runtimefallback. Herstel gebruikt een geverifieerde compatibele app of forwardfix, behoudt actuele Auth-/sinkafscherming en overschrijft nooit latere Auth-, financiële of audithistorie. [Compatibiliteit](POSTGREST-COMPATIBILITY.md), [beheer/rollback](BEHEERHANDLEIDING.md).

Eerdere tussenreleases en eerste mislukkingen blijven versiegebonden bewaard. Een natuurlijk observatievenster op3fc bewees31tabellen/outbox129gelijk en twee nieuwe cycli per job; het vervangt de finale32-tabellenproef niet. [PR72](https://github.com/duindorpdoet/platform/pull/72) bewaart de initiële integratie; [draft-PR73](https://github.com/duindorpdoet/platform/pull/73) bewaart het nieuwe bewijs en de onopgeloste infrastructuurgrens.
