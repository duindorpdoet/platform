# Het Poortenboek — V1

## Routes en grenzen

De publieke header en het mobiele menu linken naar `/poortenboek/inloggen`, of rechtstreeks naar `/poortenboek` bij een geldige kindersessie. Het kindgedeelte heeft een eigen shell met Nu (`/poortenboek`), Team (`/poortenboek/team`), Mijn boek (`/poortenboek/boek`) en Ik (`/poortenboek/ik`). `/poortenboek/demo` bestaat uitsluitend met `APP_ENVIRONMENT=staging` én `POORTENBOEK_DEMO_ENABLED=true`. Productie geeft altijd 404, ook met een verkeerd ingestelde demoflag. `DEMO26` bevat een verboden teken voor echte codes en wordt alleen door deze dubbele servercontrole toegelaten.

Alle browseracties lopen via `/api/poortenboek/[action]`: login, snapshot, entry, welcome, checklist, vote, sound, logout, parent en admin. Alleen stagingdemo's gebruiken demo-phase. De kinderbrowser bevat geen Supabase-client of database/Realtime-credentials. Een Supabase-oudersessie en een kindersessie mogen naast elkaar bestaan. Kindercookies verlenen nergens volwassen rechten.

## Datamodel en migratie

Forward-only migratie `20260927001914_poortenboek_child_sessions_and_elections.sql` voegt tien private tabellen toe:

- `poortenboek_codes`: unieke HMAC-lookup, versleutelde code, intrekking en laatste gebruik.
- `poortenboek_sessions`: uitsluitend tokenhash, absolute vervaldatum, intrekking en welkomstatus.
- `poortenboek_progress`: persoonlijke checklist en geluidsvoorkeur.
- `poortenboek_unlocks`: toekomstige, idempotente kindgebonden zegels/hoofdstukken, gekoppeld aan het bestaande `journey_events.id` (bigint) met deduplicatie per kind/bron/type.
- `poortenboek_settings` en `poortenboek_name_options`: eventdeadlines en twintig standaardnamen.
- `poortenboek_elections`, `poortenboek_ballots`, `poortenboek_commands`: generaties, geheime individuele stemmen en idempotente opdrachten.
- `poortenboek_throttles`: blijvende, atomische loginbudgetten met gehashte kenmerken.

Alle tabellen hebben RLS en geen rechten voor public/anon/authenticated. De vier API-RPC's `poortenboek_login`, `poortenboek_child_action`, `poortenboek_parent` en `poortenboek_admin` zijn security definer met lege search_path en alleen execute voor service_role. Parent/admin controleren vervolgens expliciet de geverifieerde actor en eigenaarschap/capabilities. De Node-server verkrijgt ouders via Supabase `getUser`; een client kan geen actor kiezen. Alleen household owners van submitted inschrijvingen met actieve kinderen mogen codes bekijken, vernieuwen of sessies intrekken. Organisatorisch verkiezingsbeheer vereist event_admin of groups_manage.

Er worden geen bestaande inschrijvingen, codes, samenlopen, betalingen of groepsindelingen gewijzigd. De migratie zaait alleen verkiezingsinstellingen en opties; codes ontstaan bij de eerste expliciete ouderhandeling. De ouderlijst bevat geen codes of ciphertext: Code bekijken doet een afzonderlijk geautoriseerd verzoek per kind.

## Cryptografie en sleutelbeheer

`CHILD_CODE_PEPPER` en `CHILD_CODE_ENCRYPTION_KEY` zijn **onafhankelijke** willekeurige sleutels van 32 bytes, canoniek base64, uitsluitend server-side. Genereer afzonderlijk per omgeving; nooit NEXT_PUBLIC of in een repository. Deployment valideert beide formaten, verschillende waarden en uitschakeling van productie-demo's. De build-artifactcontrole zoekt ook naar beide concrete secretwaarden.

Codes zijn zes tekens uit `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`. Zes CSPRNG-bytes modulo 32 geven een onbevooroordeelde verdeling. De HMAC-SHA-256 lookup gebruikt domein `poortenboek-code-v1\0` plus getrimde hoofdletters. Een globale unieke index voorkomt dubbel gebruik, ook na intrekking. Concurrente collisions worden atomair geweigerd; de server probeert maximaal twaalf nieuwe codes. Codes zijn nooit sessietokens.

Bewaarformaat: `v1.<nonce base64url>.<tag base64url>.<ciphertext base64url>`, AES-256-GCM via de Node-crypto-runtime, unieke willekeurige 96-bit nonce en 128-bit authenticatietag. Additional authenticated data is `poortenboek-v1:<event UUID>:<child UUID>`. Daardoor kan ciphertext niet tussen kinderen of evenementen worden verwisseld. De demo gebruikt apart AAD `poortenboek-v1:staging-demo`.

**Gecontroleerde sleutelrotatie:** zet credentialhandelingen tijdelijk in onderhoud; behoud de oude sleutels in de secretkluis; maak een nieuwe onafhankelijke sleutelset. Een uitsluitend server-side onderhoudsjob leest records met privileged toegang, ontsleutelt onder oude AAD/sleutel, berekent de HMAC met nieuwe pepper en versleutelt met nieuwe nonce/sleutel. Schrijf alle bewaarde credentialrecords (ook ingetrokken codes) transactioneel onder exclusieve credentiallocks en trek alle kindersessies in; wissel de runtime-secrets pas na die transactie en hervat verkeer met de nieuwe release. Houd de oude sleutelset beschikbaar voor versleutelde backups, niet in de actieve runtime. Controleer aantallen en gerichte decryptie zonder codes te loggen. Bij compromittering worden codes vernieuwd in plaats van uitsluitend opnieuw versleuteld. V1 heeft bewust geen ongecoördineerde live keyring: alleen een secret vervangen maakt bestaande codes onleesbaar. Maak hiervoor vóór een operationele rotatie een expliciete onderhoudsmigratie/command; geen browserendpoint.

## Sessies, login en audit

Een echte sessie gebruikt 256 willekeurige bits; alleen SHA-256(token) wordt opgeslagen. `__Host-poortenboek-session` is Secure, HttpOnly, SameSite=Lax, Path=/ en verloopt exact twaalf uur na uitgifte. Een databaseconstraint bewaakt dit interval, inclusief zomer-/wintertijd. Activiteit verlengt nooit. Iedere serveractie controleert sessie, code, actieve deelname en actueel team opnieuw. Uitloggen trekt één sessie in; Code vernieuwen trekt oude code en alle sessies atomair in. Alle kindersessies afsluiten behoudt de code. Voortgang blijft kindgebonden.

Login beperkt per vijftien minuten tot 12 pogingen per codekenmerk, 30 per apparaat en 60 per IP, met vijftien minuten blokkering en 250/650 ms foutvertraging. HMAC's scheiden code/IP/apparaatdomeinen; ruwe IP's, codes en cookies worden niet gelogd. Het apparaatkenmerk staat in een aparte Secure/HttpOnly-cookie, niet in localStorage. De reverse proxy moet het waargenomen client-IP achteraan X-Forwarded-For toevoegen (of de header volledig vervangen); de server gebruikt alleen dat laatste adres en negeert X-Real-IP. Zonder header geldt één gedeeld strikt budget; toegang tot de Node-upstream mag uitsluitend via de ingress lopen. Verkeerde, ingetrokken, geblokkeerde en onbekende codes hebben dezelfde foutmelding. Request bodies zijn ook bij streaming begrensd op 8 KiB. Origin-controle beschermt mutaties. Audit bevat actie, IDs en bij een verkiezingsreset een verplichte reden; geen credentials of ledenlijsten.

## Reisgenootjes en verkiezingen

Microteams worden bij iedere snapshot afgeleid van submitted registrations, actieve registration_children en actieve together_memberships. De stabiele identiteit is de bestaande party UUID, met registration UUID als singletonfallback. Er is geen tweede membershipmodel. Administratief delen van een walking group voegt nooit reisgenootjes toe. Pending/verworpen verzoeken doen dat evenmin.

Een veranderde kindset sluit de oude verkiezingsgeneratie en maakt een nieuwe met de actuele stemgerechtigden. Vertrokken kinderen verdwijnen direct uit volgende snapshots; hun persoonlijke checklist en verdiende zegels blijven. Kinderen zien uitsluitend voornamen, decoratieve symbolen, algemene voorbereiding en hun eigen stemkeuzes. Startinformatie bevat alleen de gepubliceerde startpuntnaam en tijd. Geen adressen, toekomstige poorten, contactpersonen of routes.

Ronde één kent 3/2/1 vonken toe aan drie verschillende namen. Na iedereen/deadline gaan de drie hoogste scores door. Ronde twee telt één stem per kind. Gelijke finalestemmen worden beslist op eerste-rondescore, daarna op oplopende MD5(event UUID + team UUID + optie UUID). Deze hash is een deterministische sorteersleutel, geen beveiligingsmechanisme. De uitslag blijft gelijk bij dezelfde team- en stemstaat. Eén kind kiest rechtstreeks. Bij geen finalestemmen bepaalt de eerste ronde de uitslag; zonder enige stem wordt geen naam verzonnen.

Stemmen zijn bewerkbaar zolang hun ronde open is. Session-locks, team-advisory-locks en request-ID/bodybinding verhinderen dubbele opdrachten of gelijktijdige rondeovergangen. Gebruikte opties kunnen niet worden verwijderd, hernoemd of gedeactiveerd; sortering blijft beheerbaar. Ouder/admin-reset vereist reden en kan alleen vóór definitieve sluiting. Na de gewone ronde-deadline verdeelt een expliciete reset de resterende tijd tot sluiting over twee rondes. Eventlocks stemmen wijzigingen af op organisatorische samenloopmutaties.

Team pollt elke twaalf seconden, alleen zichtbaar, plus focus/heropenen/eigen acties. Bij verborgen pagina's, pagehide, offline of verlopen sessie verdwijnt de oude snapshot. Navigatie gebruikt volledige documentrequests om geen eerdere kindersnapshot in de Next-routercache te bewaren. Alle private HTML/API/RSC-antwoorden krijgen no-store en noindex. Serviceworker v4 bewaart uitsluitend openbare statische bestanden en een neutrale offlinepagina; private API/RSC geeft offline een neutrale 503. Geen kindgegevens in Cache Storage, localStorage of sessionStorage. De bestaande generieke bewegingsvoorkeur mag wel lokaal staan.

## Demo, bediening en bewuste grenzen

De stagingdemo gebruikt vijf fictieve kinderen en een apart authenticated-encrypted HttpOnly-democookie met dezelfde absolute twaalf uur. Geen demonstratiehandeling schrijft naar echte sessies, registraties, verkiezingen of voortgang. Het permanente label en presentatorpaneel zijn uitsluitend bereikbaar binnen deze servermatig toegestane demo. Het paneel toont alle zes gevraagde fasen.

De drie functies **vaandelbouw, avatar/lantaarnkeuze en oefenpoort** hebben uitsluitend `coming_soon`-teaserkaarten. Geen knoppen voor deze functies, nepvoortgang of opslag. Geluid staat uit; V1 bewaart alleen de voorkeur en speelt geen geluidsfragmenten. Nieuwe routegebeurtenissen kunnen later `poortenboek_unlocks` vullen; V1 bouwt geen avondspel of oefenpoort. Geen vrije tekst, chat, media-upload of opname in de kindomgeving.

Fysieke Apple-/Samsungtoestellen en Samsung Internet waren niet beschikbaar. De acceptatiesuite gebruikt Chromium desktop, een 360px mobiele Chrome-emulatie, iPhone-WebKit en 320px/reduced-motion, met echte Secure-cookies via lokale HTTPS. PWA-cache, offline gedrag en gelijktijdige ouder-/kindcookies worden browsermatig gecontroleerd. Een echte geïnstalleerde homescreen-app blijft een fysieke toestelcontrole bij uitrol.

## Validatie uitvoeren

Gebruik uitsluitend een geïsoleerde lokale Supabase. `requireLocalTogetherDatabase` weigert remote hosts voor fixtures/concurrency/HTTPS-testserver.

- `pnpm verify` (lint, TypeScript, unit/HTTP-tests, build, artifactcontrole).
- Volledige `supabase db reset --local`, `supabase test db`, `supabase db lint`.
- `node scripts/acceptance/poortenboek-concurrency.mjs` met lokale databasevariabelen.
- Bestaande authenticated-live en together-management Playwrightflows.
- `pnpm exec playwright test --config playwright.poortenboek.config.ts`, met stagingflag, tijdelijke lokale sleutels en lokaal Supabase-servicecredential. De testserver maakt een tijdelijk zelfondertekend HTTPS-certificaat; Secure-cookies blijven ongewijzigd.

De CI-databasejob voert de kindflows met Chromium én WebKit uit. Screenshots onder `docs/screenshots/poortenboek/` gebruiken alleen fictieve gegevens. De oudercode in een screenshot behoort uitsluitend tot een lokale testdatabase.

Voor de aparte HTTPS-browserrun wordt eerst `NEXT_PUBLIC_SUPABASE_URL=https://127.0.0.1:3444 pnpm build` uitgevoerd. Laat de testprocesvariabele zelf naar de gewone lokale Supabase-URL wijzen. De testserver zet een tweede TLS-relay op 3444 naar die lokale API en laat alleen de eigen Node-child het tijdelijke certificaat vertrouwen. Zo test ook WebKit ouderbeheer zonder mixed content; productie-TLS en cookie-eisen worden niet versoepeld.
