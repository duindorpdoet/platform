# De Poortkamer V1 — technisch rapport

## Routes en data

`/mijn-huis` toont goedgekeurde poortmembers De Poortkamer. De bestaande aanmelding blijft de fallback voor aanvragers. `/uitnodiging/poort/[token]` gebruikt bestaande Supabase e-mail-OTP en een exact geverifieerde e-mailcontrole. `/admin/poortkamer/[id]` vereist organisatiecapabilities. Nieuwe serverroutes: `/api/poortkamer/invitation` (controle vóór OTP) en `/api/poortkamer/push-test` (eigen actieve abonnementen, membership + rate limit).

Forward-only migratie: `20260927142219_poortkamer.sql`. `portal_owners` blijft authoritative en krijgt rol, uitnodiger, voor-/achternaam, taak en laatste activiteit. Exact één actieve primaire eigenaar wordt afgedwongen met een partiële unieke index, portalrijlocks en uitgestelde constraints. Bestaande owners krijgen deterministisch een primaire eigenaar; ontbrekende oorspronkelijke eigenaar wordt uit de bestaande application hersteld.

Nieuwe private tabellen: `portal_team_invites`, `portal_readiness`, `portal_status_history`, `portal_room_channels`, `portal_room_messages`, `portal_room_reads`, `portal_room_reactions`, `portal_room_reports`, `portal_community_mutes`, `portal_notification_preferences`, `portal_push_outbox`, `portal_push_deliveries`, `portal_room_budgets`. RLS staat aan; directe anon/authenticated toegang is ingetrokken. De API gebruikt auth.uid en actieve memberships/capabilities, nooit user_metadata.

Nieuwe organizer/participant RPCs: `portal_room_snapshot`, `portal_visits_snapshot`, `portal_team_command`, `portal_invitation_accept`, `portal_room_update`, `portal_chat_snapshot`, `portal_chat_send`, `portal_chat_action`, `portal_notification_preferences_set`, `portal_push_test_authorize`, `admin_portal_room_snapshot`. Worker-only: `portal_invitation_check`, `portal_invitation_mail_payload`, `worker_claim_portal_push`, `worker_record_portal_push`.

Oude status-, credential-, application-save/submit- en snapshotcontracts zijn op membershiprechten aangesloten. De status-RPC behoudt de volledige bestaande plannerlogica. Nieuwe reserverings-, scan- en stop-signalen verversen de room. Geen nieuwe routeplanner, geen toegang tot kind-, ouder- of groepscontactgegevens.

## Sleutels en e-mail

Geen nieuwe deployment-envvar vereist. De migratie maakt een afzonderlijke willekeurige HMAC-SHA256-sleutel per omgeving in Supabase Vault (`poortkamer_invitation_v1`). Een uitnodiging krijgt een UUID, een HMAC-bearer daarvan en een opgeslagen SHA256-digest. Alleen een service-role mailhelper reproduceert de bearer. De outbox bevat uitsluitend de invite-ID; een ongeldige/verlopen/ingetrokken uitnodiging wordt bij verwerking onderdrukt. De browser ontvangt de link alleen via de uitnodigingsmail. Referrer/no-store/noindex voorkomen meekoppelen en caching.

Sleutelrotatie: trek eerst alle open uitnodigingen in, vervang de Vault-secret door 32 cryptografisch willekeurige bytes (hex), stuur waar nodig nieuwe uitnodigingen. Bestaande memberships veranderen niet. Geen raw tokens in migraties, audit of outbox.

Vijf premium mailtypes in de bestaande catalogus: `portal_team_invite`, `portal_team_accepted`, `portal_team_role_changed`, `portal_team_revoked`, `portal_urgent_announcement`. De bestaande ondertekende SendGrid-gateway, stagingallowlist, leases en retrylogica blijven gelden. Geen chatinhoud of ledenlijst in e-mail.

## Duurzaamheid en privacy

De bestaande minutenworker verwerkt push naast e-mail met dezelfde server-only VAPID-configuratie. Een aparte DB-crontaak `duindorp-poortkamer-maintenance` hervat verlopen pauzes, maakt aankomst-/scan-/pauzemeldingen aan en voert chatretentie uit. Push is opt-in; voorkeuren worden vlak vóór aflevering gecontroleerd. De notificatieledger dedupliceert per gebruiker en aflevering per apparaat; een stabiele browsernotification-tag onderdrukt ook dubbele zichtbare meldingen bij een crash na provideracceptatie. Netwerklevering zelf is, zoals bij elke pushprovider, geen exactly-once garantie.

Privétopics bevatten een membership-generatie. Broadcasts bevatten identifiers; Presence bevat alleen user-ID's en is een indicatie, geen autorisatie. Nieuwe rechten genereren nieuwe topics. Alle HTTP/RPC-acties valideren actuele toegang. Onzichtbare tabs pollen niet; fallback is 20 seconden. Offlinegegevens blijven uitsluitend tijdelijk in componentgeheugen, niet in localStorage, IndexedDB of Cache Storage. De service worker cachet geen private HTML/RSC/API/uitnodigingen.

## Validatie en grenzen

Lokale validatie op de geïsoleerde Supabase:

- `pnpm verify`: lint, typecheck, 208 unit/integratietests, productiebuild en scan van 826 clientartefacten.
- Volledige migration reset en pgTAP: 51 bestanden, 1.253 assertions. Inclusief rollen, uitnodigingen, concurrency-contracten, chatprivacy, communityvermeldingen, mute/retentie, plannerstatus en pushvoorkeuren.
- Echte parallelle transacties: precies één primaire eigenaar, één uitnodiging/audit bij retry en één chatbericht bij gelijktijdige retry.
- Bestaande authenticated-live, homeowner-responsive, participant-mobile-polish en together-management: 48 desktop + 12 mobiele checks.
- Bestaande Poortenboek HTTPS-regressie: 16 checks, inclusief ouder-kindwissel, gescheiden sessies en offline privacy.
- Poortkamer HTTPS: 15 flows verdeeld over desktop, 360px Chromium, iPhone WebKit, tablet en 320px reduced motion. Uitnodiging → echte OTP → Meekijker → promotie → realtime status → intrekking; daarnaast communityvermelding, PNG-verslag, gedeelde voorbereiding, uitloggen, standalone-emulatie en offline reload.
- Database-lint: geen fouten; bestaande melding over een ongebruikte variabele in `group_journey_preference`. Security advisor: uitsluitend de bestaande `pg_net`-in-public-waarschuwing. Performance advisor: geen issues.

Screenshots met uitsluitend fictieve gegevens: [`docs/screenshots/poortkamer`](../screenshots/poortkamer). De releaseworkflows controleren staging vóór productie, inclusief het bestaande toegestane-mailboxtraject en de exacte revision op `/api/health`.

 De browseracceptatie gebruikt uitsluitend lokale Supabase, echte Auth-OTP-verificatie met een lokaal door Auth uitgegeven testcode, echte RPCs en twee afzonderlijke browsersessies. E-mailtransport wordt apart door de bestaande lokale Auth-mailacceptatie en deploymentchecks gecontroleerd. Er zijn geen echte deelnemersdata of adressen als testfixtures gebruikt.

Fysieke iPhone, Samsung Internet en hardware-push kunnen niet vanuit deze container worden bewezen. Nieuwe Poortkamer-mails worden lokaal op rendering/outbox/privacy gecontroleerd; de stagingrelease controleert het gedeelde echte SendGrid/OTP-transport via de bestaande allowlist. Er worden geen uitnodigingen of pushmeldingen naar echte bewoners gestuurd voor tests. WebKit en mobiele Chromiumprofielen zijn beschikbaar. De repository bevat geen onafhankelijke goedgekeurde acteursregistratie: crew/acteurs gebruiken hun goedgekeurde poortmembership. Permanent adres/wereld/route-instellingen blijven in de bestaande gecontroleerde aanmeld-/beheerflow; het team bewerkt naam en beschrijving zonder de planner of geverifieerde locatie stilzwijgend te wijzigen.
