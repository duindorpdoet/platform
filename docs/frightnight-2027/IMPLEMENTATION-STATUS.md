# FrightNight 2027 — uitvoeringsstatus

Peildatum: 3 november 2026. Werkboom: `/home/codex/repos/duindorphalloween-frightnight-2027`, branch `codex/frightnight-2027-staging`. Basis/release vóór deze bouw: `ce6bbb52551c4005a24c04fe3a578a4c3860cc18`. Nieuwe release-SHA: releasekandidaat wordt nu gecommit; nog niet gepubliceerd op staging.

## Fase 0 — inventaris en afscherming

- Volledig overdrachtspakket gedownload, uitgepakt en gelezen; pakketverificatie 49/49 bestanden en hashes geldig. Bronmap: `/home/codex/frightnight-input-20261103/Duindorp-FrightNight-2027-Codex-Overdracht`.
- Remote main, staging en production gecontroleerd op de geaudite SHA; oorspronkelijke lokale werkboom met onderzoeksbestanden behouden.
- Effectieve staging-URL, GitHub environment, projectref `nocteiuvohesvqbowchw` en VPS-site `duindorphalloweenstg` komen overeen. Auth-instellingen en echte publieke RPC geven HTTP 200. Een eerste 401 op de REST-root was een ongeschikte probe; geen credential geroteerd.
- Historie-afwijking: 13 bekende staginghotfixes bovenop de repositoryhistorie; bestaande hashgecontroleerde reconciliatie blijft verplicht. Nieuwe backup/herstelproef, preflight en behoudsvergelijking moeten vóór migratie slagen.
- Legacy route-, poortkamer- en mailjobs blijven bestaan. Nieuwe data gebruikt uitsluitend private `fn_*`-tabellen met gecontroleerde `api.frightnight_*`-RPCs; geen nieuwe legacybetalingen, groepen, poorten of outboxregels. Nieuwe transactieberichten worden in een aparte editiegebonden sink bewaard zonder externe bezorging; de gestylede capture is uitsluitend voor bevoegde finance/regie te bekijken en af te drukken.
- GitHub staging-bootstrapactor is geverifieerd tegen bestaande event_adminbevoegdheid van Danny. Geen rollen uit wijzigbare gebruikersmetadata.

## Fase 1–3 — geïmplementeerd, verificatie loopt

- Definitieve donkere v7 overgebracht met echte beelden, fonts en vastgezette Motion 14.6.0 naar Next 16.3.5 / React 19.3.0. Publiek, Nachtpas, Mijn zone, Avondregie en testcentrum; mobiele weergave, rustige stand en systeempreferentie minder beweging. Publieke shell is onafhankelijk van een live database-RPC.
- Servercommands voor inschrijving/toestemming, startblokken, serverprijs, betalingen, QR/handmatige scan, één bestemming, deterministische routekeuze en capaciteit, samenloop en gedeelde voortgang, activiteiten, raadsels/spellen, finale, duurzame meldingen, hulp en bedankjes.
- Bewonersaanmelding met eigen eigendom/contact, foto, adresbevestiging, beoordeling, status en printborden. Regie met capabilities, paginering/exports, inhoud, testklok, gerichte herberekening, veilige afsluiting en audit.
- Mollie-testadapter met serverbevestiging, idempotente webhook/reconciliatie en refunds. Een actieve databaseclaim beschermt gelijktijdige refundverzoeken; begrensde providerreconciliatie herstelt ook een verloren refundantwoord na de PSP-idempotentietermijn. `MOLLIE_TEST_API_KEY` ontbreekt in staging; daarom expliciete contractsimulator. Dit bewijst geen externe Molliebetaling. Live betalen en echte hardware staan uit.
- Persoonlijke offlinecache maximaal 30 minuten, account-/editiegebonden en gewist bij identiteitswissel; beperkte bezoekqueue houdt command-ID/routeversie vast zonder offlinebevestiging. Downloads omvatten Nachtpas, QR-borden en noodinformatie met onafhankelijke papieren avondbediening en lokaal Lichtbaken.
- Wandelprovider en PDOK-adresadapter zijn server-side begrensd en gecachet. Synthetische testpaden gelden niet als bewezen echte wandelgeometrie; bij ontbreken blijft het adres met expliciete uitleg zichtbaar.
- Testedities kopiëren, synthetische gezinnen/huizen, testklok, injecties, herhaalbare reset en retentie zonder automatische vernietiging. Echte testeraccounts en historische financiële/auditgegevens worden niet verwijderd.

## Migraties

- `20261103012453_frightnight_2027_isolated_core.sql`: additieve private kern; nog niet remote toegepast. Bootstrap en testinitialisatie pas na bewezen isolatie en behoudsvergelijking via de bestaande stagingworkflow.

## Fase 4 — actueel bewijs

- Databasebewijs: 160/160 pgTAP geslaagd op de laatste migratiehash; zie `validation/backend-database-report.json`, `backend-pgtap.txt`, `backend-concurrency.json` en `backend-local-safety.json`; bronhash staat in het rapport. Gelijktijdige starts, scanreplays en refund-/scanrace zijn lokaal met echte transacties getoetst.
- Volledige lokale verify geslaagd: lint, typecheck, 1455 unittests, productiebuild en artifactsleutelscan. De laatste complete verify omvat ook mailcaptures en de finale server-/privacyfixes; artifactsleutelscan controleerde 697 buildbestanden. Zes optionele lokale integratietests stonden zonder hun vereiste integratieomgeving overgeslagen; de bestaande afzonderlijke CI-integratiegates blijven verplicht. De hydrationfout uit de eerste ronde is hersteld: zestien publieke Playwright-proeven opnieuw geslaagd. Zes echte lokale Auth-rollen zijn op 320/390/1440 px gecontroleerd, inclusief echte identiteitswissel, terugnavigatie en een vertraagde oude response zonder terugkerende privégegevens. Achttien muterende browserchecks bewezen offlinequeue zonder bevestiging, herstel met identieke command-ID na HTTP503, een versieconflict door een tweede tab en eenmalige visits/awards; de finale ronde op build `eRSyuhMgvmTFYkX3lfRR3` slaagt met 27 herstel-/scanchecks, 22 UI-/contractbetaal-/mailpreviewchecks en 16 publieke browserproeven op verse lokale siblingedities. Bewonerscontact, locatie, beoordeling en tijdpauze/open zijn via echte actor-API/UI gecontroleerd. Deze lokale bewijzen zijn geen gepubliceerde releaseacceptatie.
- Gerichte onafhankelijke securityreview en adaptertests zijn uitgevoerd; zie `SECURITY-REVIEW.md`.
- Lokale host was overbelast en had een volle schijf. Alleen reproduceerbare buildoutputs en eigen tijdelijke caches zijn opgeruimd; bron, oude databases, backups en historische gegevens zijn behouden. Oude lokale ondersteuningscontainers zijn gestopt; geen staging-/productiecontainer gewijzigd. Webpack wordt gebruikt na reproduceerbare Turbopack-loader-timeouts; versies/releasegates blijven behouden.

## Fase 5 — nog te bewijzen

Geen nieuwe stagingrelease uitgevoerd. Nodig: exacte-SHA CI, nieuwe versleutelde backup en geïsoleerde herstelproef, migratie/preflight/behoud, VPS-timerinventaris, mail-/editie-afscherming, deployment via dg-site-deploy, gepubliceerde health-/rolchecks, browsercontrole en begrensde belastingproef. Geen provider-, fysieke camera-, hardware-, offline- of belastingproef wordt als geslaagd aangemerkt zonder uitvoeringsbewijs. Zie de acceptatiematrix en beheerhandleiding voor afzonderlijke status en externe configuratie.
