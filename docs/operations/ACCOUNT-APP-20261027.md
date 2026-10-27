# Account, kinderboeken en app — release 27 oktober 2026

## Opgeleverd gedrag

`/app` controleert het volwassen account op de server. Een ontbrekende sessie opent het volledige inlogscherm; tijdelijke netwerkproblemen wissen de sessie niet. Google staat naast de bestaande e-mailcode. Beide gebruiken dezelfde Supabase-identiteit en serverkoppelingen. Google gebruikt SSR/PKCE met alle cookiechunks en een vaste callback. Terugkeerbestemmingen worden met `safeReturnPath` beperkt tot interne paden. De callback gebruikt de geconfigureerde publieke applicatie-origin achter de reverse proxy.

`/omgeving/kiezen` toont uitsluitend actuele ouder-, huis-, meekijk- en organisatiekoppelingen. Meerdere huizen houden hun eigen Poortkamerbestemming; meerdere meekijkrechten hun eigen toegang. Organisatie vereist bestaande capabilities. Een onbekend account krijgt de aanmeldroutes. De server controleert een opgeslagen hervatvoorkeur opnieuw.

De kinderkeuze gebruikt uitsluitend de bestaande geautoriseerde ouderlijst en beschermde `POST /api/poortenboek/parent`. Er verschijnt geen boekcode in de URL. Openen vervangt de kindcookie en laadt een nieuw document, zodat eerdere boekidentiteit/clientstate verdwijnt. De bestaande boekcode-inlog, eigen voortgang en intrekkingscontroles blijven behouden. Een bevestigde OAuth-callback trekt ook een eerdere kindcookie op dit apparaat in. Uitloggen ruimt de bedoelde kind-/volwassen sessie en apparaatspecifieke push op. Tabwisselingen tussen accounts verversen de private omgeving.

De eenmalige uitleg combineert WhatsApp, huizencommunity waar toepasselijk, installatie en vrijwillige push. Gelezen status staat per gebruiker/evenement/uitlegversie in `app_private.account_app_preferences`. Wisselen van rol, verversen en een volgende dag starten de uitleg niet opnieuw. Bestaande veertienstapsrondleidingen en aankomstbeveiliging blijven servergestuurd. `App & meldingen` kan de uitleg opnieuw openen; kinderboeken hebben openbare apphulp zonder volwassen rechten.

Het manifest behoudt app-id `/omgeving` en start op `/app`. De vroege installatie-eventregistratie ondersteunt een echte klik, annulering, aanvraag en bewezen appweergave als afzonderlijke toestanden. iPhone/iPad (ook desktopachtige iPadOS-agent) krijgt Safari/Deel/Zet op beginscherm/Voeg toe/openen. De service worker bewaart geen private schermen, auth, API of RSC-inhoud.

Push onderscheidt browsertoestemming, accountvoorkeur, browserabonnement en serverbewijs voor precies dit apparaat. De testknop selecteert uitsluitend het eigen aangevraagde apparaat; acceptatie door de pushdienst is geen bewijs van zichtbare ontvangst. Uitschakelen kan apart per apparaat. De bestaande beveiligde endpointvalidatie, limieten, herhaalde registratie, 404/410-afhandeling en operationele berichttypen blijven gelden. Bestaande VAPID-keys worden op overeenkomst gecontroleerd en niet geroteerd.

## Bron en database

- Nieuwe migratie: `20261027072938_account_app_access_and_welcome.sql`; private voorkeuren met RLS, geverifieerde account-/hervat-RPC, compatibele guidance-wrapper en minimale push-apparaatcontrole.
- PR 47 / commit `cf5f705df46140128b56014bfa3dd246ed3580f1` is opgenomen, inclusief canonieke migratie `20261027033940` en elf opslagregressies. Formulierhydratie accepteert alleen echte conceptvelden; oude impact-/commandmetadata kan geen verse preview overschrijven. Bij een echt versieconflict worden actuele gegevens en impact opgehaald en vervalt de eerdere bevestiging. De invoer blijft zichtbaar totdat de beheerder bewust kiest voor ‘Actuele versie laden en opnieuw beoordelen’.
- `repair-portal-hotfix-history.mjs` controleert beide echte project-refs, identieke bekende functiehashes, een actieve SECURITY INVOKER-cleanuptrigger en nul concepten met tijdelijke metadata. Pas daarna gebruikt staging de officiële CLI `migration repair`: canoniek `20261027033940` applied, oud `20261027032725` reverted. Dit voert geen schemawijziging of datareset uit en is herhaalbaar.
- De oude stagingbranch bevatte niet live gebruikte avondexperimenten. De branchgeschiedenis blijft behouden; de release neemt deze functies niet over naar productie. Dertien al geïnstalleerde stagingmigraties blijven alleen via de bestaande hashgepinde compatibiliteitsroute behouden.
- De werkelijk gedeployde stagingcommit `aba53894dbedae16c4e23d62dd32b54b3dea918c` met registratieheropening en zichtbare handmatige conceptpoorten is geïntegreerd. De goedgekeurde Resend-koppeling (`0960b032`, `1a1e2c24`) blijft aanwezig; centrale bootstrap verandert de actieve provider niet.

## Google: beveiligde externe configuratie

Bij inventarisatie was Google in beide Supabase-projecten uitgeschakeld. De deployment hergebruikt bestaande Google-configuratie indien aanwezig. Anders zijn in de juiste GitHub-environment beide beveiligde secrets nodig: `GOOGLE_CLIENT_ID` en `GOOGLE_CLIENT_SECRET`, afkomstig van een Google Cloud OAuth **Web application**. Deze waarden horen niet in chat, broncode of publieke runtimeconfiguratie.

| Omgeving | Supabase-project | Google Authorized redirect URI | Applicatiecallback / exacte Auth-allowlist |
| --- | --- | --- | --- |
| staging | `nocteiuvohesvqbowchw` | `https://nocteiuvohesvqbowchw.supabase.co/auth/v1/callback` | `https://staging-halloween.duindorpdoet.nl/auth/callback` |
| productie | `dtubngvxfbupgvgfrjko` | `https://dtubngvxfbupgvgfrjko.supabase.co/auth/v1/callback` | `https://halloween.duindorpdoet.nl/auth/callback` |

De Cloud-client gebruikt de echte applicatie-origins indien JavaScript-origins worden geconfigureerd. Houd consent-/publicatiestatus passend bij de echte deelnemers. Er is geen mocklogin of lokale roltoekenning. Supabase automatische identity linking koppelt betrouwbaar geverifieerde identiteiten; de app voert geen eigen accountfusie op basis van client-e-mail uit. Zonder externe clientconfiguratie is een echte Google-aanmelding niet gevalideerd; OTP blijft beschikbaar.

‘Ingelogd blijven’ bewaart de bestaande Supabase-authcookies maximaal dertig dagen per verversing, binnen de geldige server-/refreshsessie. Uitgeschakeld gebruikt browser-sessioncookies. Browser/PWA-containers delen niet op ieder apparaat hun opslag. Dit introduceert geen eigen bearer-token of langdurige localStorage-auth.

## Begrensde mailtestuitzondering

De opdrachtgever heeft voor deze release **alle mailtests** uitgesloten. `skip_mail_tests` heeft standaard `false`. Automatische pushruns mogen uitsluitend overslaan wanneer repository `duindorpdoet/platform`, exacte veertigtekenscommit, expliciete reden en een vervaldatum van maximaal 72 uur overeenkomen. De vastgelegde repositoryvariabelen zijn `MAIL_TEST_WAIVER_SHA`, `MAIL_TEST_WAIVER_EXPIRES_AT`, `MAIL_TEST_WAIVER_REASON`. Een verlopen uitzondering voor dezelfde SHA faalt vóór deployment. Een volgende commit valt weer onder normale mailacceptatie. Een handmatige dispatch kan de uitzondering voor uitsluitend die run expliciet kiezen.

CI en beide deployments schrijven de SHA/reden naar de job summary. Echte OTP-/transactionele sends, mailbox/IMAP, provider-runtimeprobes, signed-hook/webhook-mailproeven en nieuwsbrief-testacceptatie worden overgeslagen. Lokale unit-/SQL-fixtures gebruiken geen echte provider of mailbox. Backup/restore, migraties, security, build, overige tests en live appacceptatie blijven verplicht. Geen algemene CI-skip. **Mailaflevering is voor deze release niet getest.**

De automatische suppressieovername is configuratie-/gegevensmigratie, geen mailtest. Er is geen handmatige export nodig. Bij ontbrekende leesrechten kan de onafhankelijke apprelease de bestaande actieve SendGrid-provider behouden; Resend-activering blijft geblokkeerd totdat een complete automatische import is bewezen. Een ontbrekende import wordt nooit als lege lijst gecertificeerd.

## Verificatie en uitrol

Lokaal gecontroleerd: `pnpm verify` (lint, types, unitfixtures, productiebuild, client-artifactscan), alle 94 pgTAP-bestanden met 2.312 checks, en twaalf nieuwe HTTPS-browserchecks op desktop en 360px mobiel. Deze gebruiken echte geïsoleerde Supabase Auth met synthetische wachtwoordaccounts; geen echte OTP of testmail. De browserchecks omvatten servergeweigerde kinderkeuze, aparte boeken, uitloggen, eenmaal lezen over rol-/dagwissel, handmatige uitleg, iPad-installatie, klikgestuurde installatie en pushweigering zonder blokkade.

Staging moet vóór productie slagen, met versleutelde backup en geïsoleerde restore/dry-run. `accept-account-app.mjs` controleert de live RPC-contracten binnen een teruggedraaide transactie en de publieke desktop-/mobiele app-entry, annulering, API-autorisatie, installhulp en worker-cacheprivacy. Er worden geen mails of pushmeldingen verzonden. Productiepromotie vereist dezelfde commit en een volledig geslaagde stagingworkflow; een losse maintenance- of gestarte deployrun is onvoldoende. Omgevings- en applinks staan binnen de bestaande organisatie- en Poortkamermenu’s, met behoud van de volledige schermhoogte en bereikbare mobiele accountinstellingen. Aanvullend slagen twintig Poortkamercontroles op desktop, telefoon, tablet en 320px met reduced motion, zeven bestaande mobiele beheers-/deelnemerschermregressies en een browsercontrole voor het expliciet herstellen en opnieuw opslaan van een verouderd poortformulier. De workflowsummaries en het uitvoeringsrapport bevatten de daadwerkelijke SHAs en eindstatus.

Echte Google-login, pushaflevering op een toestel en mailaflevering zijn afzonderlijke bewijzen. Lokale fixtures of een native toestemming gelden daar niet als bewijs voor.

Primaire documentatie: [Google Auth](https://supabase.com/docs/guides/auth/social-sign-in/auth-google), [identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking), [officiële migration repair](https://supabase.com/docs/reference/cli/supabase-migration-repair), [PWA-installatie](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable), [beforeinstallprompt](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeinstallprompt_event).
