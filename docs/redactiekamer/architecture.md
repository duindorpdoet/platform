# Redactiekamer: architectuur en audit

Alleen staging. De featurebranch is vanaf main gemaakt en heeft de reeds bestaande staginggeschiedenis (45 commits, tot d7604fbc) met een fast-forward overgenomen. Productie, DNS en inschrijfformulieren vallen buiten deze release.

## Bestaande contracten

- Next 16 App Router, servercookies en Supabase Auth blijven de volwassen identiteit verzorgen. Kindersessies geven geen toegang.
- `app_private.content_versions` blijft de versieopslag. Een discriminator scheidt statische pagina's, nieuws en Nachtpost. De legacy openbare snapshot wordt expliciet tot pagina's beperkt.
- `event_capabilities` krijgt afzonderlijke publicatie- en communicatierechten. `content_manage` verleent geen publicatierecht voor nieuws.
- Nieuws heeft één inhoudelijke versie met kanaalplaatsingen. Een bevroren versie verandert nooit; publicatie en kanaalvervanging gebeuren onder een artikellock.
- `participant_preferences.optional_updates_consent` blijft de nieuwsbriefvoorkeur. Bestaande opt-in heeft herkomst `legacy_preferences`; nieuwe accounts en kanaalpushvoorkeuren beginnen uit. De expliciet door de organisatie gevraagde eenmalige activering op 28 september 2026 heeft een eigen administratieve bron en audit, en wordt niet als gebruikersopt-in vastgelegd. Zie het operationele runbook voor batch, aantallen en herstelvoorwaarden.
- `email_outbox`, de getekende SendGrid-hook, provider, leases, webhook en premium wrapper blijven de mailketen. Nachtpost gebruikt een eigen message type en hercontroleert consent vóór verzending.
- `push_subscriptions`, `portal_push_outbox` en `portal_push_deliveries` blijven de pushketen. Nieuws breidt deze uit met een bevroren apparaatselectie en afzonderlijke verzendstatussen.
- Afbeeldingen gebruiken een private Storage-bucket met servervalidatie en servergegenereerde varianten. Geen anonieme bucketpolicy. De server controleert elke uitlevering; alleen daadwerkelijk openbare nieuwsbeelden zijn anoniem zichtbaar. Mailbeelden gebruiken een doelgebonden ondertekende URL.
- Bestaande transactionele mails en operationele Poortkamerberichten behouden hun eigen betekenis. Nieuwsbriefafmelding raakt deze niet.

## Geraadpleegde documentatie (27 september 2026)

- Supabase changelog: https://supabase.com/changelog.md (Postgres 15.19/17.11, 25 september: geen legacy ciphers/ltree/btree_gist toegevoegd).
- RLS: https://supabase.com/docs/guides/database/postgres/row-level-security
- Storage: https://supabase.com/docs/guides/storage/security/access-control
- Cron: https://supabase.com/docs/guides/cron
- Tiptap Next: https://tiptap.dev/docs/editor/getting-started/install/nextjs (`immediatelyRender: false`).
- WebKit: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/ (Home Screen en gebruikersactie vereist).
- WebKit: https://webkit.org/blog/16535/meet-declarative-web-push/ (standaard Push API blijft bruikbaar).
- SendGrid: https://www.twilio.com/docs/sendgrid/ui/sending-email/list-unsubscribe

## Betrouwbaarheid en grenzen

Publicaties, ontvangers en queue-inserts zijn transactioneel. Unieke sleutels voorkomen dubbele enqueue. Workers claimen batches met leases; terminale afleveringen worden niet opnieuw verzonden. Een externe provider zonder idempotency-API kan bij een afgebroken verbinding na acceptatie geen mathematische exactly-once garanderen. Onzekere mailacceptatie wordt daarom apart vastgelegd voor controle, niet blind opnieuw verzonden. Provideracceptatie heet nooit automatisch aflevering.

Staging gebruikt onafhankelijk van MAIL_MODE een verplichte expliciete testlijst voor redactionele mail én push. De zichtbaarheid van de redactie, mailverzending en pushverzending zijn afzonderlijk schakelbaar. Testen gebruiken lokale geïsoleerde Supabase en providerfixtures; geen deelnemersverzending.

- Chrome permission UX: https://web.dev/articles/push-notifications-permissions-ux
- Samsung Internet: https://developer.samsung.com/browser/android/web-developer-guide.html

De volledige bediening, tabellen, rechten, stagingvariabelen, jobs, bewaartermijnen en rollback staan in [operations.md](operations.md). Testresultaten en platformgrenzen staan in [validation.md](validation.md).
