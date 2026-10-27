# Oplevering Resend-integratie — 27 oktober 2026

De implementatie staat op `codex/resend-mail-integration`, gebaseerd op de op 27 oktober opgehaalde production-commit `a2a53fd618e69dc00bf76525bb7d4a05ac360943`. Een hercontrole aan het einde van de implementatie gaf dezelfde production-SHA. De code, additieve migratie, beheerinterface en lokale regressiecontroles zijn afgerond. Resend is niet in staging of productie geactiveerd; er is geen live mail verstuurd.

Het [operationele runbook](RESEND.md) bevat de statusmapping, idempotentie-/reconciliatieregels, installatie, SendGrid-drain, incidentrollback en geraadpleegde officiële bronnen.

## Gewijzigde onderdelen en keuzes

| Onderdeel | Belangrijkste bestanden | Resultaat |
| --- | --- | --- |
| Interne gateway | `lib/mail/gateway.ts`, `lib/mail/sendgrid.ts`, `app/api/jobs/mail/route.ts` | Bestaande gesigneerde route en outbox behouden; neutrale interface, expliciete unknown/validated-uitkomsten en gecontroleerde statusopslag. De oude modulenaam is een compatibiliteitsimport. |
| Gemeenschappelijk transport | `supabase/functions/send-email-hook/{index,handler,resend,store,payload,transactional,testing}.ts` | Auth, applicatiemails en Nachtpost gebruiken dezelfde begrensde Resend HTTP-adapter. Legacy SendGrid wordt uitsluitend voor expliciet vastgelegde legacyconfiguratie gebruikt; geen automatische fallback. |
| Duurzaamheid en configuratie | `supabase/migrations/20261027011056_resend_durable_gateway.sql` | Private, geversioneerde configuratie, onveranderlijke enveloppen, leases, suppressies, providerbewuste events en service-only RPC's. Bestaande outbox/history blijft behouden. |
| Eventontvangst | `app/api/webhooks/resend/route.ts`, `lib/http/bounded-body.ts`, `lib/mail/resend-events.ts`, `package.json`, `pnpm-lock.yaml` | Officiële gepinde Svix-verificatie vóór parsing, werkelijke bytegrens, duurzame deduplicatie en veilige foutklassen. Legacy SendGrid-webhook blijft beschikbaar. |
| Beheer | `app/api/mail/settings/route.ts`, `lib/mail/admin{,-types}.ts`, `components/admin/{admin-console,email-settings}.tsx` | Werkende tab met concept/actief, runtime-status, controles zonder verzending, bewuste testopdracht, gebeurtenislog en bevestigde versiegebonden activering. Gecontroleerde Auth-UUID-allowlist plus bestaand event_admin-recht. |
| Templates en beleid | `lib/mail/{mail-catalog,templates,status}.ts`, `lib/config/server-env.ts`, `.env.example` | Bestaande templates en consent behouden, testtemplate toegevoegd, secrets uitsluitend server-side, afzenderconfiguratie centraal vastgelegd. |
| Deployment | `.github/workflows/{ci,deploy-staging,deploy-production}.yml`, `scripts/deploy/` | Nieuwe secrets en runtimekeys; centrale bootstrap, begrensde webhookprovisioning, providercontrole/replay, suppressie-import en incidentrollback. Bestaande releasepoorten blijven gelden. |
| Regressiebewijs | Nieuwe route-/Edge-/worker-/deploytests; `supabase/tests/{051,077,085,090}_*.sql`, `tests/integration/resend-planboard.test.ts`, `tests/e2e/email-settings.spec.ts` | Controle van werkelijk gedrag, bestaande domeincontracten, providergrenzen, concurrency en beheerrechten. |

Het vermoedelijke risico in de selectie van een eerder gecommuniceerde starttijd is met een regressie afgedekt: een late callback op een oudere mail beïnvloedt de gekozen vorige starttijd niet meer. De selectie gebruikt een stabiele communicatievolgorde, inclusief herkenning van bestaande `group-schedule`-dedupe-identiteiten. De bestaande concept-/bevestigings-/publicatiestappen en handmatige poortinstructies blijven leidend.

Auth antwoordt alleen met `200 {}` na duurzame acceptatie van alle vereiste ontvangers. De twee deliveries bij email_change hebben elk een stabiele identiteit; een geslaagde eerste delivery wordt bij herstel niet opnieuw aangeboden. De identiteit gebruikt geverifieerde invocationmetadata en een onafhankelijke HMAC-sleutel. De actuele Supabase-broncode is hiervoor onderzocht: `webhook-id` wordt per HTTP-retry vernieuwd, terwijl `metadata.uuid` buiten die lus ontstaat. Auth-tokenmateriaal wordt niet als mailbody in audit-/eventrecords opgeslagen.

Het eerste verzendmateriaal wordt bevroren. Een onbekende Resend-uitkomst kan alleen met dezelfde provider, key en inhoud binnen 23 uur en 55 minuten automatisch worden hersteld; daarna is reconciliatie vereist. Provideracceptatie, aflevering, klacht en suppressie blijven afzonderlijk herkenbaar. Een webhook kan geen nieuwe mail, publicatie of toestemming veroorzaken. Rolling deployment met de oude twee-argumentclaim-RPC is behouden zonder Resend-pogingen aan een oude worker opnieuw aan te bieden.

## Uitgevoerde controles

Alle controles hieronder draaiden lokaal op deze wijziging met Node.js 24, pnpm 11.25.0, Next.js 16.3.5 en Supabase CLI 2.117.0. De databasetests gebruikten een afzonderlijke native lokale Supabase-stack, opgebouwd uit alle repositorymigraties en seed. Productiedata zijn daarvoor niet gebruikt.

| Controle | Feitelijk resultaat |
| --- | --- |
| `pnpm verify` | Geslaagd: ESLint zonder waarschuwingen, TypeScript, **423 unittests**, productiebuild en clientartefactscan. Eén opt-in integratietest is in deze standaardrun overgeslagen en afzonderlijk hieronder uitgevoerd. |
| Clientartefactscan | **1.213 bestanden**, geslaagd. Nieuwe serversecret-namen zijn in de controle opgenomen. |
| Native `supabase db reset` | Alle migraties en seed succesvol toegepast. De migratie activeert geen Resend-configuratie. |
| Native `supabase test db` | **90 bestanden, 2.242 tests, PASS**. Omvat bestaande start-, planbord-, handmatige poort-, mail- en Nachtpostcontracten. |
| `MAIL_INTEGRATION_CONTAINER=… pnpm exec vitest run tests/integration/resend-planboard.test.ts` | **1 ketentest geslaagd** met echte PostgreSQL-transacties, drie overlappende workerkicks, de gesigneerde interne gateway, echte Resend-adapter en gemockte provider-HTTP. |
| Standaard Playwright-suite | **50 geslaagd, 140 overgeslagen** volgens de bestaande fixture-/omgevingsvoorwaarden. De overgeslagen tests zijn geen geslaagde controles. |
| Native geauthenticeerde planbord-/mailbeheer-suite | **10 geslaagd**: acht bestaande planbordtests en twee nieuwe mailbeheertests met echte lokale Auth/API, inclusief directe link, mobiel, conceptopslag, ontbrekende credentials en een geweigerde eventbeheerder zonder systeemrecht. |
| Native schema lint | Geslaagd met waarschuwingen in **13 bestaande domeinroutines**; geen nieuwe mailroutine gerapporteerd. |
| Native security advisors | Alleen de bestaande `extension_in_public`-waarschuwing voor `pg_net`; geen nieuwe mailbevinding. |
| `git diff --check` | Geslaagd. |

De ketentest controleert de beschermde wijziging van een reeds gepubliceerde tijd, afzonderlijke publicatie, eerdere SendGrid-acceptatie, exacte individuele ontvanger/template/oude en nieuwe tijd, idempotente dispatch en dubbele gesigneerde webhook. Door echte overlappende claimtransacties wordt concurrentie getest, niet alleen opeenvolgend aanroepen van een mock.

Gerichte regressies dekken onder meer onleesbare/ongeldige 2xx-antwoorden, 429/retry-informatie, timeouts, gedeeltelijke Auth-acceptatie, opslagfouten na acceptatie, raw-body verificatie, oversize zonder Content-Length, onbekende events, vroege callbacks, provider-/omgevingsisolatie, uit-volgorde events, klacht na aflevering, verlopen idempotentie, configuratieraces en verouderd activeringsbewijs. Een fixture in test 051 is expliciet geïsoleerd van reeds door seed geactiveerde Nachtpostvoorkeuren; productieconsent is niet aangepast.

De lokale provider-HTTP is gemockt. Deze resultaten bewijzen geen echte provideracceptatie, DNS-verificatie, webhookvoorziening of ontvangst in een postbus. Browserbeelden en demodata zijn niet als afleveringsbewijs gebruikt. Remote GitHub CI en de overige omgevingsgebonden releaseacceptaties zijn niet door deze lokale resultaten vervangen.

## Werkelijk ingerichte omgeving

Er is uitsluitend een geïsoleerde lokale Supabase-testomgeving gestart, gemigreerd en gebruikt voor SQL-, Auth-/browser- en ketentests. Er zijn geen externe providerwebhooks, domeinen, DNS-records, Resend-contacten of broadcasts aangemaakt of gewijzigd. Staging en productie zijn niet gedeployed of gemigreerd.

De benodigde Resend sending-/beheercredential, webhooksecret en onafhankelijke identiteitssleutel waren hier niet beschikbaar. Er is daarom geen live providercontrole of testmail uitgevoerd. Er zijn geen echte secrets in code, documentatie, browser of chat opgenomen.

## Resterende installatie en release

1. Stel per GitHub-environment/runtime veilig `RESEND_API_KEY`, `RESEND_ADMIN_API_KEY`, `RESEND_WEBHOOK_SECRET`, `MAIL_IDENTITY_SECRET` en `MAIL_ADMIN_USER_IDS` in. Behoud het afzonderlijke `SEND_EMAIL_HOOK_SECRET`, `AUTH_SITE_URL` en het bestaande mail-/Auth-/Nachtpostbeleid. De signing-secret kan door de daarvoor bestemde deploymentprovisioning worden verkregen; stuur waarden niet via chat. De [secrettabel in het runbook](RESEND.md#secrets-en-externe-inrichting) noemt rechten en bestemmingen.
2. Verifieer het werkelijke afzenderdomein, DKIM/SPF en bestaand DMARC-beleid; controleer expliciet dat open-/kliktracking uitstaan. Laat uitsluitend de deploymentvoorziening het eigen webhookendpoint provisionen.
3. Exporteer en beoordeel de volledige relevante SendGrid-suppressies en importeer deze met `import-mail-suppressions.mjs`. Zonder deze afronding blijft Resend-activering geblokkeerd; lokale uitschrijvingen en bekende klachten blijven behouden.
4. Doorloop de bestaande integratie-/stagingrelease met encrypted backup/restore en migratiereconciliatie. Maak in Beheer een concept, voer de nietverzendende controles uit en start daarna bewust een toegestane concepttest. Verifieer de bijbehorende echte providerwebhook en echte staging-Auth-postbusontvangst. Een Resend-testadres is alleen een gesimuleerde provideruitkomst.
5. Bevestig activering pas met geldig, actueel bewijs voor precies die configuratie en credentials. Promoveer uitsluitend de succesvol geaccepteerde staging-SHA via de bestaande productieautorisatie. Inventariseer bestaande SendGrid-unknown-pogingen en behoud de legacywebhook/credentials gedurende de afgesproken drain-/rollbacktermijn.

Bij oplevering loopt `main` 143 productiecommits achter op deze production-basis. De featurebranch wordt daarom als zelfstandige reviewbare branch aangeboden; een vergelijking met de bovengenoemde production-SHA toont uitsluitend de integratie. Dit is geen directe productiepromotie of vervanging van de stagingpoorten.
