# Staginginventaris FrightNight 2027

Read-only controle op 3 november 2026. Baseline: `ce6bbb52551c4005a24c04fe3a578a4c3860cc18` in `duindorpdoet/platform`. Geen migratie, seed, Authverzoek, mail, push, deploy of productieactie uitgevoerd tijdens deze inventaris. Er zijn geen deelnemersrijen, Authgebruikersrijen, mailpayloads, secretwaarden of vaultwaarden in dit document opgenomen.

## Doelbinding en actuele werking

| Onderdeel | Actueel bewijs | Uitkomst |
| --- | --- | --- |
| Stagingomgeving GitHub | Environment `staging`, branch policy uitsluitend `staging` | Correct |
| Publieke host | `https://staging-halloween.duindorpdoet.nl` | Correct |
| VPS-site / gebruiker | Workflow vereist `duindorphalloweenstg` | Correct in bron en laatste geslaagde deploy |
| Dedicated runner | `dg-sites-vps-01-duindorphalloweenstg-01`; workspace onder `/srv/sites/duindorphalloweenstg/actions-runner/_work/` | Expliciete workflowchecks |
| Supabase-URL | GitHub stagingvariable `https://nocteiuvohesvqbowchw.supabase.co` | Komt overeen met ref |
| Supabase-ref | GitHub stagingvariable `nocteiuvohesvqbowchw` | Correct |
| Supabase-project | Connector Duindorpdoet: `staging-halloween`, `ACTIVE_HEALTHY`, regio `eu-central-1`, PostgreSQL `17.6.1.166` | Correct |
| Runtimehealth | GET `/api/health`: `status=ok`, `environment=staging`, `revision=ce6bbb52551c4005a24c04fe3a578a4c3860cc18`, `registrationMode=staging_test` | Geslaagd |
| Publieke Data API | POST `/rest/v1/rpc/event_public_snapshot` met geconfigureerde anonsleutel, profiel `api`, bestaande 2026-slug | HTTP 200, uitsluitend publieke snapshot |
| Authconfigbereikbaarheid | GET `/auth/v1/settings` met geconfigureerde anonsleutel | HTTP 200; geen OTP aangevraagd |
| Nieuwe editie | Alleen 2026 en zeven oude synthetische `evening-load-*` events aangetroffen | Nog geen 2027-editie |

De actuele geconfigureerde anonsleutel is exact de actieve legacy anonsleutel van dit Supabase-project. De JWT-ref past en de sleutel is niet verlopen. Er is ook een actieve moderne publishable key beschikbaar, maar een overstap is voor deze bouw niet noodzakelijk. Beide actuele sleutels geven bij de OpenAPI-root `/rest/v1/` HTTP 401 met de misleidende melding `Invalid API key`, terwijl de echte publieke RPC en Authsettings HTTP 200 geven. Een rootprobe is hier dus geen bruikbaar bewijs van credentialdrift. Er is geen sleutel veranderd of geroteerd.

Het historische project `dtubngvxfbupgvgfrjko` is geen bestemming voor deze opdracht. De bovenstaande binding is positief vastgesteld; productie is niet geprobed of gewijzigd.

## Laatste release en herstelbewijs

Laatste geslaagde stagingrun: [41433832508](https://github.com/duindorpdoet/platform/actions/runs/41433832508), gestart 2 november 2026 11:04 UTC en afgerond 11:17 UTC, exact baseline-SHA. De run was `workflow_dispatch`; de aparte postbusontvangstacceptatie was expliciet overgeslagen. Dit is geen bewijs van een echte geslaagde OTP- of transactionele bezorgtest op deze datum.

De geslaagde backupjob rapporteerde:

- Versleutelde databasebackup gecontroleerd op authenticiteit.
- Netwerkloos, geïsoleerd herstel met alle **236 tabelfingerprints** gelijk.
- **12 Storage-objecten** meegenomen; migratie-dry-run geslaagd.
- Preflight op dezelfde SHA: `backupRetainedPrivately=true`, `restoreVerified=true`, `migrationDryRunVerified=true`.
- Artifact `redesign-backup-staging-41433832508-1` (id `13135987607`) aanwezig en niet verlopen; GitHubretentie tot **2 december 2026 11:10 UTC**.
- Browserartifact `account-app-staging-ce6bbb52551c4005a24c04fe3a578a4c3860cc18` aanwezig tot 16 november 2026.

Dit is het bestaande herstelpunt, geen vooraf verstrekt herstelbewijs voor nieuwe migraties. Iedere nieuwe release moet opnieuw de exacte SHA, migratiehashes en actuele data door backup/herstel, preflight en behoudsvergelijking halen.

De backupstraat gebruikt AES-256-GCM, contextgebonden encryptie en een HMAC-ondertekend `proof.json`. Zij omvat database, rollen/rechten, Storage, configuratie en Vault-herstel. De hersteldatabase heeft `--network none` en `cron.launch_active_jobs=off`, zodat herstelde wachtrijen niet naar externe diensten bellen. De private VPS-kopie staat volgens preflight onder `~/.local/share/duindorp-release-backups/staging/<run>-<attempt>/`. De fysieke beschikbaarheid/retentie van die lokale kopie is tijdens deze read-only sessie niet rechtstreeks via SSH gecontroleerd.

Appreleases blijven immutable. Gebruik het bestaande `dg-site-deploy`-release-/rollbackpad; geen force-push, database-reset of destructieve downmigratie. De laatste groene app-SHA is hierboven vastgelegd. Na nieuwe testwrites vereist dataherstel een gerichte reconciliatie; een oude volledige dump terugzetten kan die nieuwe feiten verliezen.

## Migratiedrift en databasegrens

Actueel: **153 geïnstalleerde migraties**, **140 baseline-migratiebestanden**, geen repository-only versie. De 13 remote-only migraties zijn exact de bekende staginguitbreiding:

| Versie | Naam |
| --- | --- |
| 20261024024428 | evening_readiness_evidence |
| 20261024025222 | evening_visit_information |
| 20261024034343 | evening_route_transaction_order |
| 20261024042005 | evening_ordinary_capacity |
| 20261024043647 | evening_finale_commitments |
| 20261024050939 | evening_live_route_context |
| 20261024054230 | evening_route_candidates |
| 20261024064423 | evening_route_reviews |
| 20261024065647 | evening_physical_admission |
| 20261024071646 | evening_legacy_route_binding |
| 20261024100115 | evening_closed_current_instruction |
| 20261024112932 | evening_nonblocking_channel_reads |
| 20261024125139 | evening_cockpit_aggregation |

Gebruik `staging-installed-history.mjs` en `push-staging-release.mjs`: alleen de expliciet bekende bronnen van de vastgelegde historische SHA worden tijdelijk opgehaald, op SHA-256 gecontroleerd en na afloop verwijderd. De bestaande wrapper bevat `--include-all` ná deze gecontroleerde inventaris; voer geen losse blinde CLI-push uit. `repair-portal-hotfix-history.mjs` controleert de exacte bekende functie-/wrapperketen en trigger voordat de officiële CLI de bekende historie kan reconciliëren. Geen lege migraties of nieuw verzonnen historie toevoegen.

Actueel `api`: **0 basetabellen**. Actueel `app_private`: **197 basetabellen, alle 197 met RLS**. De echte publieke RPC werkt met profiel `api`; geen tabellen of private schema's toevoegen aan exposed schemas. Nieuwe operationele relaties blijven onder de private grens met een klein expliciet API-oppervlak, actor/event/capabilitychecks en minimale EXECUTE-grants.

## Actieve jobs en onbedoelde mail

| Job | Frequentie | Actuele opdracht |
| --- | --- | --- |
| `duindorp-halloween-route-dispatch` | Iedere minuut | `app_private.dispatch_all_due_routes()` |
| `duindorp-poortkamer-maintenance` | Iedere minuut | `app_private.poortkamer_tick()` |
| `duindorp-halloween-mail-outbox` | Iedere minuut | `app_private.dispatch_mail_worker()` |

`job_configs.mail_outbox` is actief met de staginghost als endpoint en een bestaande secretreferentie. Geen secretwaarde gelezen. Insert in legacy `email_outbox` activeert bovendien `email_outbox_immediate_dispatch`; alleen cron pauzeren voorkomt geen dispatch.

De actieve trigger `payment_requests_transactional_mail` roept `enqueue_payment_state_email` aan. De geïnspecteerde definitie bevat **geen event-/testfilter**, zoekt ontvangers uit bestaande `household_members` en `auth.users`, en maakt `payment_link_ready`, `payment_reported` en `payment_confirmed` aan. Legacy `email_outbox` heeft **geen `event_id`**. De nieuwe kern mag fictieve betalingen dus niet via bestaande huishoudens of `payment_requests` afhandelen. Een JSON-testflag op `events` beschermt deze oude trigger niet.

Vereiste vóór eerste seed: editie-/omgevingsgrens vóór enqueue én dispatch, afzonderlijke duurzame FrightNight-notificaties/outbox of expliciet geteste adapter, standaard sink/capture, alleen toegestane transactionele testontvangers. Bewijs voor aanmaken, statuswijziging, betaallink en retry: nul nieuwe onbedoelde legacy-outboxregels en nul externe bezorgingen. Globale bestaande jobs blijven intact.

De legacy routewrapper selecteert events met `event_route_settings.planner_mode=dynamic` en fase `ready/live/paused`, zonder nieuwe FrightNight-domeincheck. Hij roept daarnaast `worker_duinpad_evenings` aan; die sluit alle vervallen oude Duinpad-evenings af en kan bedankmail maken. Maak daarom voor de nieuwe kern geen legacy dynamic route-settings, walking-groups of Duinpad-eveningregels aan zonder bewuste adapter. Houd de nieuwe editie in eigen geteste domeinrelaties en scoped commands.

De bestaande `/api/jobs/mail` verwerkt tevens Redactiekamerpublicatie, portalpush en editorialpush. Een testeventflag alleen is daar geen pushafscherming. Nieuwe testnotificaties moeten een eigen gecontroleerd pad hebben. In staging staan historische `NEWSLETTER_SENDING_ENABLED` en `WEB_PUSH_SENDING_ENABLED` op true in de workflow; wijzig de bestaande 2026-stromen niet globaal ter vervanging van nieuwe editie-isolatie.

## Retentie, afsluiting en timers

De nieuwe dedicated-runnergate inventariseert vóór seed eigen crontab, systeem-/gebruikerssystemdtimers en bereikbare `/etc/crontab`, `/etc/anacrontab`, `/etc/cron.d` en de gebruikelijke hourly/daily/weekly/monthly-mappen. Zij bewaart alleen naam, leesstatus, scope en hash. Staging-/FrightNight-systeemcron vereist een exact beoordeelde hash; gewone apt-/logrotatietaken vereisen geen stagingreviewhash. Bestandslezingen zijn begrensd. Onleesbare bestanden/mappen en private root-/andere-gebruikercrontabs blijven expliciete grenzen; er wordt geen sudo of permissieomzeiling gebruikt. Deze nieuwe VPS-uitvoering is op deze auditdatum nog niet als geslaagd bewezen.

| Categorie | Aangetroffen gedrag | Gevolg voor maandenlang testen |
| --- | --- | --- |
| Operationele oude eventdata | `api.retention_preview` is preview-only, standaard 30 dagen | Geen generieke delete uitvoeren |
| Poortkamerchat | Actieve maintenance verwijdert berichten plus cascades één kalendermaand na `local_date`; memberships/audit blijven | Nieuwe testchat niet ongemerkt aan dit oude pad koppelen |
| Portalpush | Maintenance verwijdert completed regels na 30 dagen | Nieuwe in-appnotificaties apart bewaren |
| Redactiekamer | `editorial_retention` aggregeert afgeronde campagnes en verwijdert hun mail/events/ontvangers na 30 dagen én na eventretentiegrens; oude newsreads na 30 dagen | Geen nieuwe testcampagnes in legacytabellen |
| Poortpauzes | Maintenance kan goedgekeurde gepauzeerde poorten automatisch openen na `pause_until`; centrale eventafsluiting wordt gerespecteerd | Nieuwe testklok/zonepauzes moeten eigen scope en klokkeuze hebben |
| Duinpad-evenings | Minuutworker kan verlopen evenings afronden en bedankmail en audit schrijven | Gebruik eigen finale-adapter en expliciete testklok |
| Edge Functions | Eén actieve `send-email-hook`, versie 392, JWT-verificatie uit; ondertekende webhookcontrole in app | Geen Authcodes vanuit seed/CI uitlokken |
| GitHub timers | Alle vijf aanwezige workflows gelezen; geen `schedule`/`cron`-trigger aangetroffen | Geen GitHubperiodieke taak in huidige repo |
| VPS/systemd/externe timers | Geen rechtstreeks SSH-/OS-timerinventaris uitgevoerd | Nog als expliciete pre-seed/releasecheck te bewijzen |
| Backupartifact | GitHub 30 dagen | Kies nieuw herstelpunt voor langere testperiode |
| Browserartifact | GitHub 14 dagen | Screenshots zijn tijdelijk bewijs, geen databehoud |

Voor de nieuwe testeditie moet het product vóór seed een zichtbare beschermde einddatum, seedversie en expliciet cleanupbeleid krijgen. Testbedrijfstijd beïnvloedt uitsluitend de gekozen editie; JWT/TLS/provider-/machineklok blijven werkelijke tijd. Bewaar synthetische scenario's maandenlang; laat geen legacy automatische sluiting of chatretentie de nieuwe editie wissen. Cleanup moet uitsluitend expliciete eigen editierelaties raken, gedeelde Auth/profielen behouden, de scope vooraf tonen en het resultaat auditen. RET-01 t/m RET-05 zijn nog uit te voeren op de nieuwe kern.

## Releasegates en noodzakelijke gerichte aanpassingen

Huidige straat: CI → exacte SHA fast-forward naar `staging` → versleutelde backup en netwerkloos herstel/migratieproef → dedicated runnerchecks → `pnpm verify` → preflight → gecontroleerde stagingmigratie → volledige behoudsvergelijking → mailconfig/Edge Function → `dg-site-deploy duindorphalloweenstg ...` → Supabaseconfig → security advisors → health/public/protected smoke → account/browseracceptatie. Productionpromotion maakt geen deel uit van deze opdracht.

Voor FrightNight moeten doelgericht worden aangepast:

1. Workflow hardcode `EVENT_SLUG=duindorp-halloween-2026` vervangen door expliciete 2027-testeditie. Nieuwe runtimekeys moeten ook in de VPS-runtimeallowlist en envvalidator.
2. Exacte nieuwe migratie toevoegen aan `REVIEWED_RELEASE_MIGRATIONS`; backup-/restorebewijs bevat die exacte bronhash. Originele tabellen/kolommen, Auth, betalingen, outbox/audit en Storage behouden hun strikte vergelijking. Nieuwe tabellen betekenen geen nieuwe brede data-uitzondering.
3. `configure-supabase.mjs` niet stilzwijgend legacy registratie-/notificatie-RPC's tegen de nieuwe domeinflow laten aanroepen; scoped 2027-config verifiëren en bestaande mailjob/Authconfig behouden.
4. Huidige `staging_mail.py` vraagt automatisch OTP aan en mag niet automatisch lopen: de opdracht staat Authcodes uitsluitend toe wanneer de tester zelf inlogt. Vervang de automatische releasepoort door no-send ondertekende hook/providerconfigcontrole, sink/outbox-isolatiebewijs en echte anonieme/rolweigering-smoke. Markeer echte OTP-/postbusontvangst eerlijk als handmatige testeracceptatie. Dit is een opdrachtwijziging, geen ongeautoriseerde algemene mailwaiver.
5. Huidige accountacceptatie gebruikt bestaande 2026-actor en voert rollbackcommands tegen oude records uit; de nieuwe acceptatie moet 2027-contracten en synthetische eigen scope gebruiken. Geen bestaande huishoudens als testfixture.
6. Public/protected/PWA-smoke en screenshots moeten de nieuwe FrightNightroutes/branding controleren. Auth-/cache-/no-sendcontroles en autorisatieweigeringen blijven concrete gates.

Actuele securityadvisors melden de bestaande categorieën RLS-zonder-policy, extension-in-public, anoniem/authenticated uitvoerbare SECURITY DEFINER en leaked-password-protection. Dit is historische context, geen toestemming om private tabellen breed te openen. Controleer specifiek alle nieuwe tabellen/functies en verifieer na migratie opnieuw.

## Open bewijs en blokkades

- **Geen doelbindingsmismatch**; echte publieke RPC en Authsettings zijn bereikbaar.
- Nieuwe editie, seed-/mailisolatie, eigen retentie, concurrency, PSP en nieuwe serverflows zijn nog niet bewezen door deze inventaris.
- Geen Mollie-/andere PSP-secretnaam aanwezig in de zichtbare stagingsecretinventaris. Provideraccountconfig kan elders bestaan; echte PSP-testacceptatie is niet bewezen. Lever adapter/contractproef en vermeld ontbrekende configuratie exact.
- Directe VPS-/externe timerinventaris ontbreekt nog. Geen globale cron-/mailuitschakeling gebruiken als vervanging.
- Dit document is fase-0-bewijs op baseline-SHA, geen acceptatie- of releaseverklaring voor gewijzigde code.

## Gerichte vervolgconfiguratie

Na de read-only inventaris is op expliciete taakautorisatie één stagingvariable toegevoegd: `FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID`. De gekozen identiteit is bevestigd door exact één profiel `Danny Goldenbelt` met bestaande actieve `event_admin`-capability en een bevestigd, niet-verwijderd, niet-geblokkeerd Authaccount. Alleen de minimale profielnaam/UUID/actiefbevestiging is gelezen; geen contactadres, deelnemersgegevens of mailhistorie. De variable is teruggelezen. Er is hierdoor geen nieuwe rol, editie, seed of Authmail aangemaakt; het service-only bootstrapcommand blijft achter de nieuwe releasebehoudsvergelijking.

De nieuwe code bevat een expliciete stagingbinding, schema-/RLS-/EXECUTE-/sinkcontrole, behoud van de drie legacyjobs, bootstrap na de ongewijzigde behoudsvergelijking en no-send HTTP-/browsergates. De automatische `staging_mail.py`-OTPacceptatie is uit de stagingrelease vervangen door die concrete controles volgens de opdracht. Echte tester-OTP en werkelijke providerbezorging blijven afzonderlijk te registreren; deze vervanging claimt geen bezorgbewijs. De productieworkflow is niet aangepast.

De release bevat bovendien een directe dedicated VPS-timerinventaris vóór bootstrap/seed. Het gesaneerde artifact bevat uitsluitend namen, status en commandhashes; een onvolledige inventaris of niet beoordeelde stagingtimer stopt de seed. De service-only `frightnight_initialize` gebruikt de geverifieerde organisatieactor als expliciete gedelegeerde taakreferentie, zonder Authlogin of JWTimpersonatie. Hij maakt alleen nog ontbrekende ownerless synthetische scenario's aan en bewaart 2026, Auth, huishoudens, legacybetalingen en outbox. De aparte ingelogde browseracceptatie gebruikt vijf volledig nieuwe synthetische Authidentiteiten en een eigen siblingevent; geen historische actor wordt als testgebruiker ingelogd.

## Aanvullende Auth-hardgate vóór vrijgave

De finale configuratiereview ontdekte dat staging `AUTH_MAIL_MODE=live` gebruikte terwijl alleen transactionele mail door de twee bestaande testinboxen werd begrensd. De reeds geverifieerde actieve Danny-actor stond niet in die twee inboxen. De noodzakelijke reparatie is een aparte server-only environmentsecret `FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS` met precies drie huidige ontvangers: beide bestaande testers en die geverifieerde actor. Deze secret is op 3 november 2026 met stdin geconfigureerd; er zijn geen adressen gelogd, geen platte tekstbestanden geschreven en geen OTP of mail verzonden. Een read-only hashvergelijking gaf uitsluitend vier ware booleans terug: actor bestaat, actief/bevestigd, toegestaan en bestaand beheerder. De transactionele lijst is niet gewijzigd.

De gewijzigde stagingstraat zet Auth op allowlist, deployt de gesigneerde hook en bewijst deze actorbinding vóór bootstrap/initialisatie. Een ontbrekende Authsecret of live/sandboxmodus blokkeert FrightNight-stagingauth vóór gatewayopslag of providerverkeer. Het werkelijke remote hookbeleid is hiermee nog niet als uitgerold geclaimd: de nieuwe head moet eerst volledige CI en de normale release doorlopen. Zie [auth-allowlist-report.json](validation/auth-allowlist-report.json).

## Eerste releasepoging en herstelconfiguratie

Push-CI 41582099453 op exact `090773a0a15a49316128e08004e026f1541c6e04` slaagde volledig: drie jobs, normale mailtests, 4520 databaseproeven, 1514 applicatietests en 23 publieke browserproeven. De daaropvolgende stagingrelease 41583941440 stopte vóór migratie/deploy in de geïsoleerde backup-dry-run. Encryptie, authenticatie en herstel van alle 236 bestaande tabelfingerprints waren geslaagd; `CREATE POLICY` op `storage.objects` werd als `postgres` geweigerd omdat de herstelcontainer de gerichte Supabase-policydelegatie miste.

Read-only bronmetadata bevestigt `session_preload_libraries=supautils` en `supautils.policy_grants` met `postgres`/`storage.objects`. De tabel blijft van `supabase_storage_admin`; `postgres` is geen superuser of lid van die eigenaarrol. De gerichte reparatie neemt uitsluitend deze waargenomen capability op in de versleutelde export en configureert de netwerkloze herstelcontainer met de statische minimale policydelegatie. Er worden geen remote grants, ownership, RLS, migraties of appdata gewijzigd. In twee lege disposable containers is als rechtstreeks ingelogde niet-superuser bewezen: zonder delegatie weigert policy-DDL, met delegatie slaagt dezelfde policy; tabelwijziging, ownershipwissel, beleid op een niet genoemde tabel en aannemen van de eigenaarrol blijven geweigerd. Een nieuwe volledige CI en geslaagde echte backup/herstel/dry-run blijven vereist. Zie [restore-policy-parity-report.json](validation/restore-policy-parity-report.json).

De volgende exacte CI 41585240647 op `aad96668a3744b0dbfe09111956537ee53d9ff8d` slaagde volledig, inclusief 1519 applicatietests en 4520 databaseproeven. Stagingrelease 41587423924 bewees vervolgens de volledige versleutelde backup, restore van 236 tabellen en 12 objecten en beide nieuwe migraties in de netwerkloze dry-run. Het bewaarde artifact is `redesign-backup-staging-41587423924-1` (13208503054, vervalt 3 december 2026). De daaropvolgende dedicated validatie stopte vóór remote migratie/deploy op acht testasserties: twee unitfixtures stuurden localhost-origin maar gebruikten de echte staging-originconfig. Alleen die testconfig is geïsoleerd; de echte Origin-guard en afwijzingsasserties blijven bestaan. De fout is zonder credentials/netwerk gereproduceerd, daarna zijn beide suites lokaal en met staging-origins 12/12 groen en de volledige suite met staging-origins 1519/1519 groen (zes bestaande optionele skips). Dit geeft geen vrijstelling voor de volgende exacte CI of releasegates. Zie [staging-origin-fixture-report.json](validation/staging-origin-fixture-report.json).
