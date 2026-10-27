# Resend via de bestaande Supabase-mailgateway

De implementatie is gebaseerd op production `a2a53fd618e69dc00bf76525bb7d4a05ac360943`, opgehaald op 27 oktober 2026. De bestaande outbox, domeintriggers, worker, Auth-OTP-generatie, toestemming, startpublicatie en poortuitnodigingen blijven leidend. Deze migratie activeert geen provider, publicatie of bestaande mail.

## Verzend- en ontvangstcontract

- Auth → gesigneerde `send-email-hook` → duurzame Auth-envelop → dezelfde kleine Resend HTTP-adapter. Alleen na duurzame provideracceptatie van **alle** ontvangers antwoordt Auth met `200 {}`. Een e-mailadreswijziging heeft afzonderlijke sleutels voor oud en nieuw adres.
- Domeintrigger → bestaande `email_outbox` → bestaande `/api/jobs/mail` → `lib/mail/gateway.ts` → dezelfde Edge Function en adapter. Relevantie, materiaal, uitnodiging en Nachtpost-consent worden vóór iedere dispatch opnieuw gecontroleerd. Er is geen tweede uitgaande queue of nieuwsbriefcontactlijst.
- Resend → `/api/webhooks/resend` → Svix-verificatie van de ongewijzigde body → minimaal duurzaam `email_events`-record → providerbewuste projectie. Een callback verstuurt nooit mail en verandert nooit starttijd, betaling, registratie of consent.

`mail_config_versions` en `mail_config_heads` vormen de centrale configuratiebron. Next-beheer en Edge lezen deze via service-only RPC's. Nachtpost behoudt de bestaande geautoriseerde afzendernaam uit het bevroren campagnemateriaal; afzenderadres en reply-to volgen de centrale versie. De legacy `SENDGRID_FROM_*`-variabelen dienen uitsluitend voor de eerste, behoudende bootstrap; wijzigingen in een browser of gecachte `serverEnv` activeren geen afzenderconfiguratie. Iedere envelop bewaart de gebruikte configuratieversie.

## Statusregels

| Bewijs | Transport | Aflevering / gevolg |
| --- | --- | --- |
| Geldig Resend API-ID of `email.sent` bij een bekende envelop | accepted | Nog geen afleverbevestiging |
| `email.delivered` | accepted | delivered: ontvangen door mailserver, geen leesbevestiging |
| `email.delivery_delayed` | accepted | delayed; provider verzorgt retries, geen app-resend |
| `email.bounced` | accepted | bounced; veilige redenklasse en lokale suppressie |
| `email.complained` | accepted | complained en suppressie, ook na delivered |
| `email.failed` | accepted | failed met veilige providerklasse; geen automatische nieuwe semantische mail |
| `email.suppressed` | accepted | suppressed met eigen providerredenklasse |
| Netwerkfout, timeout, 5xx, onleesbare 2xx of ontbrekend ID | unknown | Herstellen met dezelfde envelop binnen het venster |
| 429 | deferred | Begrensde `Retry-After` wordt behouden |
| Definitieve validatie/credentialafwijzing | failed | Geen automatische providerfallback |
| Sandbox of bestaande providerprobe | validated | Geen providerverzending, geen bewijs van acceptatie of aflevering |

Aflevering, klachten en suppressie zijn afzonderlijke velden op `mail_envelopes`. Een laat sent/delayed-event maakt delivered niet ongedaan. Een klacht na delivery blijft zichtbaar, terwijl de outbox geen nieuw verzendrecht krijgt. Events worden door `unique(provider, provider_event_id)` gededupliceerd; de event-ID komt van `svix-id`, het providerbericht-ID van `data.email_id`.

Koppeling vereist provider, runtimeomgeving, werkelijk opgeslagen providerbericht-ID en ontvangerhash. Tags zijn alleen correlatie. Vroege events blijven duurzaam ongekoppeld tot het echte API-ID is opgeslagen. Auth heeft eigen enveloppen zonder gefingeerde outbox- of kindregistratie.

## Idempotentie, leases en reconciliatie

Outboxsleutel: `mail/<outboxUUID>/1`. De eerste poging bevriest de volledige providerpayload in de private envelop. Een retry gebruikt exact dezelfde key, provider, configuratie en inhoud. Veranderde domeininhoud vereist een nieuwe semantische outboxmail; de bestaande relevantiechecks blijven ook voor retries gelden.

Auth-identiteit gebruikt een HMAC met de onafhankelijke `MAIL_IDENTITY_SECRET`, per geverifieerde aanvraag en ontvanger. De actuele Supabase-bron maakt **binnen** de HTTP-retrylus een nieuwe `webhook-id`; die header is dus geen dedupesleutel. `metadata.uuid` wordt vóór de lus aangemaakt en blijft bij dezelfde invocation gelijk. Oudere payloads vallen terug op geverifieerd tokenmateriaal en Auth-sendtijdvelden. Bewaar `MAIL_IDENTITY_SECRET` stabiel door hooksecret-rotaties heen; roteer deze identiteitssleutel pas nadat openstaande Auth-pogingen zijn afgehandeld of verlopen. Tokenmateriaal verschijnt uitsluitend in HMAC-invoer en het onmiddellijke providerrequest, nooit in de opgeslagen Auth-payload, tags of algemene logs. Nieuwe invocationmetadata onderscheidt ook toevallig gelijke nieuwe OTP's. Controleer dit contract bij een GoTrue-upgrade; de echte staging-Auth-postbustest blijft vereist.

Resend bewaart keys 24 uur. Automatische dispatch stopt conservatief na **23 uur en 55 minuten** vanaf de eerste poging. Ook een gewijzigde credentialfingerprint blokkeert een onzekere retry. Status wordt `reconcile`; er bestaat geen onbeperkte opnieuw-sturen-knop. Dit is geen onbeperkte exactly-once-garantie.

`worker_mail_prepare` vergrendelt de logische envelop vóór een providercall. Parallelle requests krijgen een bestaande acceptatie of busy-resultaat. De outbox houdt de bestaande claim/lease/SKIP LOCKED-keten. De nieuwe worker geeft de omgeving expliciet mee aan de claim-RPC; de bestaande twee-argumentvariant blijft uitsluitend als rolling-deploymentcontract bestaan en markeert oude claims als SendGrid. Zo wordt ook een oude worker die ná de metadata-backfill claimt niet later als een nooit aangeboden Resend-mail behandeld. Verlopen Edge-leases worden unknown; alleen een Resend-envelop binnen het veilige venster wordt opnieuw claimbaar. Een fout bij `worker_mail_finish` of de outbox-RPC wordt expliciet behandeld, ook na provideracceptatie.

Handmatige afhandeling van `reconcile`:

1. Stop met automatische pogingen; wijzig nooit de key, provider of body om een onbekende uitkomst te omzeilen.
2. Zoek de envelop en providerlogs via het opaque outbox-ID/configversie. Bekijk OTP-inhoud niet in gewone logs of exports.
3. Controleer met de providerbeheercredential het gevonden providerbericht: provideraccount, omgeving, ontvanger en bevroren inhoud. Een tag alleen is geen bewijs.
4. Laat een bevoegde operator de geverifieerde ontvangst via de service-only `worker_mail_finish` vastleggen met het bestaande envelop-ID en claimtoken. Gebruik het werkelijk gevonden provider-ID. Dit roept geen providerverzending aan en reconcileert reeds opgeslagen callbacks.
5. Als acceptatie niet kan worden bewezen: laat de poging in `reconcile`. Eventuele nieuwe communicatie vereist de bestaande domeinrechten, actuele inhoud/toestemming en een eigen expliciet bevestigde semantische opdracht.

## Beheer en activering

Open `/admin?view=settings&settingsTab=email`. Vereist: een door `getUser()` geverifieerde Auth-user-ID op runtime-allowlist `MAIL_ADMIN_USER_IDS` **én** bestaand `event_admin`-recht. Een eventbeheerder zonder die allowlist kan de omgevingbrede koppeling niet lezen of wijzigen. Er is geen self-service toekenning of authorization op `user_metadata`.

1. Concept opslaan; actieve configuratie blijft werken.
2. Controle uitvoeren zonder verzending: centrale versie, afzenderdomein, tracking uit, runtimevoorziening en gesigneerde Edge-probe. Dit is configuratievalidatie; het verstuurt niets.
3. Bewust een concepttest naar een toegestane echte postbus of een expliciet benoemd Resend-testadres inplannen. Ook dit gebruikt de bestaande outbox. Dubbelklikken/tabs voor dezelfde ontvanger en versie delen tien minuten dezelfde opdracht; HTTP-retries hebben bovendien een duurzaam commandreceipt.
4. Wachten op provideracceptatie en een passende, geldig ondertekende delivered-webhook. Gesimuleerde provideradressen bewijzen geen echte postbusontvangst. De normale stagingallowlist wordt niet uitgebreid; provideradressen zijn uitsluitend beschikbaar voor expliciete `mail_provider_test`-opdrachten.
5. Suppressie-import afronden.
6. Impact bevestigen en activeren. De server controleert expected revision/config-ID, hash, actuele DNS/credentialchecks en de concepttest. De testacceptatie mag maximaal dertig minuten oud zijn en moet bij de huidige sending-credentialfingerprint én webhooksecretfingerprint horen. Een race of stale concept geeft conflict.

## Secrets en externe inrichting

Stel waarden uitsluitend via de bestaande beveiligde GitHub-environment/runtimevoorziening in, afzonderlijk voor staging en productie. Deel ze niet in chat, repo, URL, browservelden of localStorage.

| Naam | Bestemming / doel |
| --- | --- |
| `RESEND_API_KEY` | Beperkte sending-access key, bij voorkeur beperkt tot het afzenderdomein; Edge-transport, serverstatus alleen aanwezigheid |
| `RESEND_ADMIN_API_KEY` | Afzonderlijke beheercredential voor domeincontrole en webhookprovisioning; nooit doorgestuurd naar de verzendadapter |
| `RESEND_WEBHOOK_SECRET` | Alleen Next-ontvangstverificatie; deployment kan dit uit de eigen providerwebhook provisionen |
| `MAIL_IDENTITY_SECRET` | Onafhankelijke willekeurige sleutel van minimaal 32 tekens; Edge-HMAC voor stabiele Auth-identiteiten en credentialfingerprints |
| `MAIL_ADMIN_USER_IDS` | Runtime-beheerde komma-gescheiden geverifieerde Auth-UUID's, plus vereist bestaand event_admin-recht |
| `SEND_EMAIL_HOOK_SECRET` | Bestaande afzonderlijke Standard Webhooks-signing key voor Auth/interne gateway |
| `AUTH_SITE_URL` | Bestaande Auth-links / branding; geen provider- of webhooksecret |

Behoud `MAIL_MODE`, afzonderlijk `AUTH_MAIL_MODE`, `MAIL_ALLOWED_RECIPIENTS`, `APP_ENVIRONMENT`, `NEWSLETTER_SENDING_ENABLED` en `EDITORIAL_ALLOWED_RECIPIENTS`. De workflows behouden de bestaande stagingbeperkingen en echte postbusacceptatie. `AUTH_MAIL_MODE` staat nu ook expliciet in de runtime-keylijst.

Verifieer het afzenderdomein in Resend, richt de opgegeven DKIM/SPF-records en het bestaande DMARC-beleid correct in, en controleer dat open- en kliktracking uitstaan. De code wijzigt geen DNS, MX, trackinginstelling of provideraccountcontactlijst.

Webhookendpoints:

- productie: `https://halloween.duindorpdoet.nl/api/webhooks/resend`
- staging: `https://staging-halloween.duindorpdoet.nl/api/webhooks/resend`

Eventset: `email.sent`, `email.delivered`, `email.delivery_delayed`, `email.bounced`, `email.complained`, `email.failed`, `email.suppressed`.

CI/deployment is de enige provisioningeigenaar (`configure-resend-webhook.mjs`). Het script doorloopt de lijst begrensd, weigert dubbele eigen endpoints, verandert uitsluitend de exacte eigen omgevings-URL en print geen signing secret. De UI configureert geen providerwebhook. Voor een echte gecontroleerde replay vult de operator `RESEND_ACCEPTANCE_EVENT_ID` in met een bestaande, aan de juiste envelop gekoppelde provider-event-ID. `test-resend-webhook.mjs` gebruikt Resends replay-API; een lokaal verzonnen signature is geen productiegezondheidsbewijs.

## SendGrid-drain en rollback

De additieve migratie labelt bestaande begonnen/accepted/onzekere uitkomsten als SendGrid. Historische provider-ID's/events worden niet naar Resend omgelabeld. Bootstrap behoudt de effectieve legacy-afzender en provider; Resend wordt uitsluitend na de beheerflow actief voor nieuwe enveloppen.

- Nieuwe, nooit aangeboden rows volgen de actieve configuratie.
- Begonnen Resend-enveloppen blijven bij Resend, ook na een rollback.
- Begonnen SendGrid-pogingen zonder veilig bevroren contract, in het bijzonder unknown, vereisen reconciliatie. Ze worden niet via Resend opnieuw aangeboden.
- Accepted/delivered worden niet opnieuw geclaimd. Providervertraging is geen app-retry.
- Failed/suppressed, lokale uitschrijvingen, publicaties en semantische dedupe blijven behouden.
- `/api/webhooks/sendgrid`, de verificatiedependency en oude runtimecredentials blijven beschikbaar voor late events en incidentrollback.

Voor activatie: exporteer de volledige relevante SendGrid hard-bounce/complaint/invalid-suppressies, normaliseer een privaat JSON-bestand naar `[{"email":"...","reason":"bounce|spamreport|unsubscribe|invalid"}]`, controleer volledigheid en voer in de juiste omgeving uit:

```sh
node scripts/deploy/import-mail-suppressions.mjs /private/path/reviewed-export.json --confirm-complete-export
```

Het script valideert records en verstuurt uitsluitend ontvangerhashes naar de service-RPC. Het legt de bronhash en afronding vast. Bestaande lokale editorial suppressies en bekende SendGrid-bounces/klachten worden ook behouden. Een nieuwsbriefuitschrijving blokkeert Nachtpost, geen nieuwe Auth-code. Zonder volledige export/controle blijft activering geblokkeerd; ontbreken van export is geen nieuwe toestemming.

Incidentrollback blijft een bewuste servicehandeling met bestaande beheerrechten en expected revision. Verifieer eerst de behouden SendGrid-key/afzender extern, zet de runtime-allowlisted `MAIL_ROLLBACK_USER_ID` en voer uit:

```sh
node scripts/deploy/rollback-mail-provider.mjs EXPECTED_REVISION 'Concrete incidentreden en controle' --confirm-legacy-provider-reviewed
```

Dit verplaatst alleen de actieve configuratiepointer en schrijft een minimale auditregel; het verstuurt niets en herschrijft geen lopende envelop. Verwijder oude secrets/endpoints pas na een expliciet afgesproken drain-/bewaarvenster en een gecontroleerde inventarisatie van oude unknown-pogingen. Een code-revert naar een worker die de nieuwe enveloppen niet begrijpt is geen veilige rollback.

## Release, privacy en verificatie

Promotie blijft via development/integratie → succesvolle staging → **dezelfde SHA** naar productie, met bestaande encrypted backup/restore-, migratiereconciliatie- en acceptatiepoorten. Deze wijziging geeft geen toestemming voor live testmail, provideractivering of DNS-wijzigingen. Staging kan bestaande andere migratiegeschiedenis bevatten; verzoen die via de bestaande gates, nooit met een reset of een omzeiling van releasechecks.

Nieuwe tabellen staan in `app_private`, hebben RLS en geen directe browser-/service-tablegrants. Service-only RPC's zijn de enige transportingang; beheer vereist daarnaast het gecontroleerde actorrecht. Auth bewaart geen OTP-body. Eventdata bevat alleen IDs, tijden, ontvangerhash en vaste foutklassen. De normale operationele bewaartermijn/preview-only verwijderprocedure geldt ook voor de nieuwe envelop- en eventrecords. Beoordeel opruiming van bevroren applicatiepayloads samen met outbox/audit-retentie; deze migratie verwijdert niets automatisch en unresolved-pogingen mogen niet tijdens hun reconciliatievenster verdwijnen.

Gerichte tests: gateway/Resend-parser, officiële Svix-byteverificatie, beheerrechten/versieraces/secretredactie, dual email_change en gedeeltelijk herstel, duurzame SQL-projecties en leases, late callback op oudere startmail, exact geadresseerde planbordcorrectie en de volledige lokale keten met drie parallelle workerkicks. De provider is in lokale tests gemockt; dat bewijst geen live aflevering.

Bronnen, gecontroleerd op 27 oktober 2026: [Supabase Send Email Hook](https://supabase.com/docs/guides/auth/auth-hooks/send-email-hook), [HTTP-retryimplementatie](https://github.com/supabase/auth/blob/master/internal/hooks/hookshttp/hookshttp.go), [invocationmetadata](https://github.com/supabase/auth/blob/master/internal/hooks/v0hooks/v0hooks.go), [Resend send API](https://resend.com/docs/api-reference/emails/send-email), [idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys), [Svix-verificatie](https://resend.com/docs/webhooks/verify-webhooks-requests), [events](https://resend.com/docs/webhooks/event-types), [tags](https://resend.com/docs/dashboard/emails/tags), [testadressen](https://resend.com/docs/dashboard/emails/send-test-emails), [providerreplay](https://resend.com/docs/api-reference/webhooks/replay-event).
