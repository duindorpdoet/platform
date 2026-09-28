# Redactiekamer gebruiken en beheren

Na de stagingacceptatie is op 27 september 2026 ook productie vrijgegeven met Redactiekamer, Nachtpost en Web Push ingeschakeld. De forward-only migratie is `20260927165020_redactiekamer.sql`. De productiepromotie vereist dezelfde commit met een volledig geslaagde stagingdeployment. Bestaande pagina-, ouder-, Poortkamer-, mail- en PWA-contracten blijven bestaan.

## Toegang en routes

| Capability | Bevoegdheid |
| --- | --- |
| `content_manage` | Nieuwsconcepten, categorieën en media beheren |
| `content_publish` | Nieuws publiceren, plannen en archiveren |
| `communications_manage` | Nachtpostconcepten, doelgroepen, voorbeelden en media beheren |
| `communications_send` | Eigen testmail, definitief inplannen, annuleren, veilige retries en nieuws-push |
| `event_admin` | Alle bovenstaande handelingen |

De centrale desktopnavigatie en mobiele Meer-navigatie tonen Redactiekamer alleen met een toepasselijke capability en ingeschakelde featureflag. Een uitsluitend redactionele beheerder ontvangt geen operationele deelnemersgegevens in de admin-dashboardbootstrap.

Stagingroutes:

- `https://staging-halloween.duindorpdoet.nl/admin` → Redactiekamer.
- `https://staging-halloween.duindorpdoet.nl/nieuws` en `/nieuws/[slug]`.
- `https://staging-halloween.duindorpdoet.nl/omgeving/nieuws/ouders`.
- `https://staging-halloween.duindorpdoet.nl/omgeving/nieuws/huizen`.
- `https://staging-halloween.duindorpdoet.nl/omgeving/nieuws/[slug]` voor beveiligde push-deeplinks; login behoudt de bestemming.
- `https://staging-halloween.duindorpdoet.nl/omgeving/communicatie`.
- `/nachtpost/afmelden?token=…` toont een bevestiging; GET meldt nooit af. `/api/editorial/unsubscribe` verwerkt de getekende POST en RFC 8058 one-click.

## Nieuws en media

Schrijf één artikel, kies een private afbeelding en vul alt-tekst in. De compacte Tiptap-editor slaat uitsluitend gevalideerde JSON op. Zowel de serverroute als database begrenzen blokken, links, attributen, omvang en nesting. Publicatie vereist een hero met alt-tekst. De website en portalen gebruiken dezelfde renderer als het redactionele voorbeeld. De Nachtpostpreview gebruikt de werkelijke premium e-mailrenderer.

Kanaalinstellingen worden samen met het concept opgeslagen. Per kanaal zijn lijstzichtbaarheid, uitlichting, begin/einde, CTA en pushmoment instelbaar. De interface gebruikt Amsterdamse kloktijden; ontbrekende of dubbelzinnige zomertijdmomenten worden geweigerd. De database bewaart timestamptz. Een nieuwe inhoudelijke versie laat de huidige publicatie ongemoeid tot de ingeplande vervanging. Een uitgeschakeld kanaal wordt bij bevestigen gearchiveerd. Eén unieke index bewaakt maximaal één live versie per artikel en kanaal.

De mediatheek accepteert stilstaande JPG/PNG/WebP tot 12 MB en 60 megapixels, controleert bestandstype en afmetingen, verwijdert metadata en maakt bron-, hero-, kaart-, portaal-, e-mail- en OG-varianten. Het opgeslagen focuspunt bepaalt de uitsnede. De bucket `editorial-media` is privé. Routes controleren openbare publicatie of actuele portaal-/redactierechten; mailbeelden hebben afzonderlijke doelgebonden handtekeningen. In gebruik zijnde beelden kunnen niet worden verwijderd. Slugs van eenmaal gepubliceerde artikelen blijven stabiel.

## Nachtpost en toestemming

Nachtpost is optioneel redactioneel nieuws. Betalingen, OTP, startinformatie, groepskoppelingen en veiligheidsinformatie blijven bestaande transactionele berichten. De bestaande `optional_updates_consent` is de enige e-mailtoestemming; accountbezit, een inschrijving of een huisaanmelding betekenen geen opt-in. Er is geen nieuw inschrijfformulier of automatische toestemmingsmigratie toegevoegd. Een toekomstige inschrijfcheckbox kan met expliciete tekst dit bestaande voorkeurencontract gebruiken; tot die tijd geeft het volwassen account toestemming op Communicatievoorkeuren.

Doelgroepen zijn een OF-combinatie van gekozen volwassen rollen. Aanvullende filters gelden met EN. De server normaliseert en dedupliceert e-mailadressen en trekt ontbrekende toestemming, afmeldingen, suppressions en providerbounces af. Kinderlogins, kindcodes en kindnamen worden nooit als ontvangers gebruikt. Algemene abonnees zijn uitsluitend bestaande volwassen accounts met expliciete consent; het platform heeft geen afzonderlijke anonieme nieuwsbriefinschrijving.

Voor verzending: inhoud opslaan → ontvangers controleren → desktop/mobiel voorbeeld → testmail naar het eigen beheeradres → op provideracceptatie wachten → definitieve bevestiging. Planning bevriest zowel de ontvangers als de geselecteerde nieuwsversies. De eindbevestiging controleert opnieuw het verwachte aantal. Een geplande campagne kan vóór de start worden geannuleerd. Na de start kan inhoud alleen via een nieuwe, gedupliceerde campagne worden gewijzigd. Gearchiveerde bronartikelen moeten vóór het opnieuw inplannen worden vervangen door beschikbare publicaties.

De actieknoppen staan onder het formulier en scrollen mee. **Verzending controleren** haalt de actuele ontvangers zelf op, ook nadat een campagne opnieuw is geopend. De testmailstatus ververst bij terugkeer vanuit de mailapp en met **Status vernieuwen**. Een opgeslagen concept zonder wijzigingen krijgt geen nieuwe versie. Een geaccepteerde of afgeleverde test van exact dezelfde inhoud binnen dezelfde campagne blijft geldig, ook bij dubbele versies die eerder door opnieuw opslaan zijn ontstaan. Andere inhoud of een gedupliceerde campagne vereist een eigen test. Dit is vastgelegd in de forward-only migratie `20260928141258_nachtpost_testmail_and_save.sql`; bestaande mails en ontvangers worden daarbij niet aangepast of opnieuw verstuurd.

Iedere ontvanger heeft één outboxregel met unieke campagneversie/e-maildigest. Ook vlak vóór het versturen worden consent en huidige portaalrechten hercontroleerd. Het e-mailadres staat alleen in de private ontvangersnapshot en de bestaande mail-outbox, niet in de adminprojectie of auditpayload. Staging testmails moeten eveneens op beide testlijsten staan.

De bestaande ondertekende SendGrid-hook levert individuele berichten, geen BCC. Dezelfde premium wrapper, afzenderconfiguratie, reply-to en eventwebhook blijven in gebruik. Nachtpost voegt veilige contentblokken, gewone tekst, voorkeuren-/afmeldlinks en `List-Unsubscribe` plus `List-Unsubscribe-Post` toe. Open- en kliktracking staan bewust uit; eventuele providerstatistieken worden als indicatief aangeduid. Provideracceptatie is nog geen aflevering.

## Push en PWA

De bestaande service worker, manifest, VAPID-configuratie, pushsubscriptions en Poortkamer-outbox worden uitgebreid. Bij publicatie worden ontvangers en actieve apparaten atomair vastgelegd, ook voor een later pushmoment. Overlappende ouder-/huisrechten leveren per artikelversie en apparaat één doel op. De worker controleert opnieuw toestemming, rechten, actuele publicatie en apparaatstatus. Later aangemelde apparaten worden niet achteraf aan de bevroren selectie toegevoegd.

Een lease en afzonderlijke apparaatresultaten voorkomen dat concurrerende workers hetzelfde werk uitvoeren. Tijdelijke providerfouten krijgen backoff; HTTP 404/410 trekt het betreffende abonnement in. Acceptatie heet ‘Naar pushservice verzonden’. Een klik wordt alleen voor het betreffende apparaat en de ingelogde eigenaar vastgelegd. Bij een verbroken verbinding of verlopen werklease na mogelijke acceptatie wordt de verzending apart gehouden: een externe provider zonder idempotency-API kan geen absolute exactly-once garanderen. Deze gevallen krijgen geen blinde retry. Handmatige retries herhalen geen reeds geaccepteerde apparaten.

Het lockscreen toont alleen een vaste titel en generieke nieuwstekst. De service worker accepteert alleen begrensde interne nieuwslinks, focust/navigateert een bestaande app of opent een nieuwe en gebruikt een stabiele notificatietag. Onbekende links gaan naar Mijn omgeving. Geen privépagina, API, afmeldtoken, RSC-respons of pushpayload wordt in Cache Storage bewaard. Offline verschijnt een neutrale pagina. Abonnementsherstel volgt de bestaande instellingenflow; er is geen automatische nieuwe toestemmingsvraag.

Installeren blijft maximaal één suggestie per ingelogd account per dag, met Later. Browsertoestemming volgt uitsluitend op een gebruikersactie na de bestaande uitleg. iOS/iPadOS vereist een ondersteunde geïnstalleerde Home Screen-webapp; feature detection verbergt onbruikbare acties. Zie [Apple/WebKit](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/), [Chrome](https://web.dev/articles/use-push-notifications-to-engage-users) en [Samsung](https://developer.samsung.com/browser/android/web-developer-guide.html).

## Configuratie en jobs

| Variabele | Betekenis |
| --- | --- |
| `REDACTIEKAMER_ENABLED` | Adminmodule en schrijf-API zichtbaar, standaard false |
| `NEWSLETTER_SENDING_ENABLED` | Nachtpost voorbereiden/versturen, standaard false |
| `WEB_PUSH_SENDING_ENABLED` | Achtergrondpushworkers toegestaan, standaard false |
| `EDITORIAL_ALLOWED_RECIPIENTS` | Expliciete testadressen buiten production; leeg blokkeert |
| `EDITORIAL_TOKEN_SECRET` | Onafhankelijke willekeurige serversecret van minimaal 32 tekens voor HMAC-SHA256 |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | Bestaande publieke VAPID-sleutel |
| `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Bestaande serverconfiguratie, nooit in clientbundles |

`MAIL_MODE`, `MAIL_ALLOWED_RECIPIENTS`, `SEND_EMAIL_HOOK_SECRET`, SendGrid-credentials en `CRON_SECRET` blijven nodig. Staging gebruikt MAIL_MODE=allowlist én de aparte redactionele lijst. De Edge-hook controleert de redactionele lijst onafhankelijk van de Next-server; een onbedoelde MAIL_MODE=live heft de grens niet op. De operationele pushworker krijgt op staging dezelfde begrensde lijst.

De productieworkflow zet `REDACTIEKAMER_ENABLED`, `NEWSLETTER_SENDING_ENABLED` en `WEB_PUSH_SENDING_ENABLED` op `true` en geeft deze ook door aan de app-runtime. Productie heeft een eigen `EDITORIAL_TOKEN_SECRET` in het GitHub-environment; deze sleutel wordt niet gedeeld met staging. De productie-Edge-hook krijgt daarnaast `APP_ENVIRONMENT=production` en `NEWSLETTER_SENDING_ENABLED=true`, zodat de bestaande mailgateway Nachtpost kan verwerken. De toestemming- en publicatiecontroles blijven van toepassing. Functies inschakelen publiceert geen artikel en maakt geen campagne aan. De Poortenboek-demo blijft uitsluitend op staging beschikbaar.

De bestaande minuutcron roept `/api/jobs/mail` aan. Die publiceert eerst nieuws en verwerkt afzonderlijk de push- en mailqueues. Mail mag uitstaan terwijl nieuws wordt gepubliceerd. `api.worker_editorial_tick`, `worker_claim_editorial_push`, `worker_record_editorial_push`, `worker_finish_editorial_push` en `worker_newsletter_material` zijn uitsluitend service-rolefuncties. Het bestaande `worker_claim_outbox` blijft de mailqueue-ingang en behoudt alle eerdere betaal-/portaalguards.

HMAC-tokenformaat: `v1.<base64url(uuid of versie:media)>.<HMAC-SHA256>`, met gescheiden context voor unsubscribe en mail-media. Tokens bevatten geen e-mailadres. Rotatie van EDITORIAL_TOKEN_SECRET trekt bestaande links in; bewaar daarom de sleutel zolang oudere campagnes hun afmeld-/beeldlinks nodig hebben, of voer een expliciete tweesleutelovergang uit in een aparte migratie. Publiceer of log de sleutel en volledige afmeld-URLs niet.

## Bewaartermijnen en herstel

Individuele leesstatussen verlopen na 30 dagen; views/CTA-totalen blijven geaggregeerd. Afgeronde of definitief mislukte pushdetails verdwijnen na 30 dagen, met behoud van anonieme aantallen per nieuwsversie/kanaal. Dezelfde delete-trigger werkt bij de bestaande Poortkamer-opruiming. Nachtpostontvangers, outboxadres en afzonderlijke events verdwijnen na de bestaande evenementtermijn `operationalDataRetentionDays` (standaard 30 dagen na de avond), en niet eerder dan 30 dagen na afronding. De campagne behoudt alleen anonieme verzendtotalen. Toestemmings-/afmeldvoorkeuren en noodzakelijke gehashte suppressions blijven bestaan om toekomstige ongewenste verzending te verhinderen.

Rollback: zet eerst NEWSLETTER_SENDING_ENABLED en WEB_PUSH_SENDING_ENABLED uit, daarna eventueel REDACTIEKAMER_ENABLED. Gepubliceerde nieuwsfeeds blijven leesbaar. Zet zo nodig afzonderlijke publicaties op archief. Rol de app terug naar de vorige stagingrelease; de additieve migratie kan blijven staan. Verwijder geen ontvanger- of outboxregels om een gedeeltelijke verzending ‘opnieuw’ te beginnen. Controleer onzekere provideracceptatie via outbox-ID/provider-ID voordat een nieuwe campagne wordt overwogen.

De GitHub-stagingomgeving accepteert uitsluitend de stagingbranch. Deze release volgt daarom de bestaande PR-, CI- en stagingdeploymentroute. De branchbeveiliging en productie-releasegate worden niet verruimd. Checkout, APP_REVISION en de dedicated stagingrunner blijven aan de exacte commit gebonden.

## Opslag en contracten

Nieuwe private tabellen: `news_categories`, `news_articles`, `news_placements`, `news_reads`, `news_metrics`, `editorial_media`, `editorial_media_usage`, `newsletter_campaigns`, `newsletter_recipients`, `editorial_suppressions`. Nieuwe kolommen op bestaande `content_versions`, `participant_preferences`, `portal_push_outbox` en `portal_push_deliveries` bewaren type, conceptplanning, expliciete consent, nieuwsverwijzing en apparaatresultaten. Er is geen tweede authenticatie, contentversieopslag of transportqueue.

RPC-groepen: `admin_news_*` (concept/publicatie/archief/pushraming), `news_feed`/`news_record`/`news_push_clicked` (kanaalweergave/eigen metingen), `admin_editorial_*` (snapshot/categorie/media/retry), `admin_newsletter_*` (doelgroep/concept/preview/test/planning/annulering), `editorial_preferences*` (eigen voorkeuren) en de bovengenoemde workerfuncties. Alle EXECUTE-grants zijn expliciet. Publieke pagina-RPCs worden tot `content_kind=page` beperkt, zodat redactionele concepten niet in legacy snapshots belanden. RLS blijft ook op niet-exposed private tabellen ingeschakeld.
