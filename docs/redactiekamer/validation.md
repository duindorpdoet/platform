# Redactiekamer: validatie

Alle destructieve tests gebruiken de geïsoleerde lokale Supabase. Providerresponses zijn lokale fixtures; er worden geen deelnemeradressen of pushdiensten aangeschreven. `scripts/acceptance/editorial-concurrency.mjs` weigert een niet-lokale database-URL.

## Suites

- `pnpm verify`: lint, TypeScript, volledige unit/integratiesuite, production build en clientartifactcontrole.
- `pnpm exec supabase db reset --local` en `pnpm exec supabase test db`: volledige migratieketen en pgTAP inclusief redactieautorisatie, kanaalprivacy, versie-immutability, consent, doelgroepen, enqueue, pushleases/apparaten, webhook en retention.
- `pnpm exec supabase db lint --local --schema api,app_private --level warning`: nieuwe functies zonder relevante waarschuwingen; de bestaande ongebruikte `snapshot`-variabele in `api.group_journey_preference` staat buiten deze wijziging.
- `node scripts/acceptance/editorial-concurrency.mjs`: acht gelijktijdige publicaties, edits, scheduler-ticks, apparaatclaims en campagneplanningen.
- `pnpm exec playwright test --config playwright.editorial.config.ts`: werkelijke admin/publicatie-/portal-/Nachtpostflow op desktop, 360px Android/Chromium, iPhone/WebKit en 320px met reduced motion. De provideracceptatie is een lokale fixture; transporthandtekeningen, headers en 404/410/503 worden afzonderlijk door integratietests gecontroleerd.
- Bestaande authenticated/PWA-browserflows controleren regressies in sessie, navigatie en offline gebruik.

De HTTPS-harness gebruikt dezelfde Secure-cookies en een lokale TLS-relay voor Supabase; beveiliging wordt niet uitgezet om browsertests te laten slagen. CI installeert echte Chromium- en WebKit-browsers. Op deze Linuxwerkplek zijn de benodigde WebKitbibliotheken apart geladen; de WebKit-engine zelf wordt daadwerkelijk uitgevoerd.

## Handmatige acceptatie op apparaten

1. Open staging als allowlisted volwassen testaccount. Controleer desktopnavigatie, mobiele Meer-navigatie, toetsenbordfocus en dialogs.
2. iPhone/iPad: open in Safari, voeg toe aan beginscherm en open de geïnstalleerde app. Kies Communicatievoorkeuren, schakel ouder-/huisnieuws in en druk bewust op de pushactie. Sta OS-meldingen toe. Sluit de app, publiceer één testbericht en controleer generieke lockscreenmelding en de juiste deeplink na eventueel opnieuw inloggen.
3. Android Chrome en Samsung Internet: herhaal in gewone browser en geïnstalleerde PWA. Controleer Installeren/Later, systeemtoestemming, twee apparaten, uitzetten en verlopen abonnementen.
4. Selecteer ouder- én huizenkanaal voor een account met beide rollen: maximaal één melding per apparaat. Plan een latere push en controleer dat vóór het moment geen verzending optreedt.
5. Trek een rol of consent in vóór dispatch: geen aflevering. Log account A uit, open B en ga offline: geen privé-inhoud van A in caches.
6. Controleer de echte testmail op desktop/mobiel in Apple Mail, Gmail en Outlook. Controleer afbeeldingen, alt-tekst, CTA, gewone tekst en one-click/manual unsubscribe. Geen deelnemerscampagne starten.
7. Zet motion uit en controleer leesbaarheid op 320px, zichtbare focus en dat acties bereikbaar blijven met het toetsenbord.

Fysieke Apple-/Samsungtoestellen en echte Apple Mail/Gmail/Outlook-clients zijn vanuit deze werkplek niet beschikbaar. Browseremulatie is geen bewijs van OS-pushbezorging op een fysiek toestel. De bovenstaande acceptatiestappen blijven nodig voor een onvoorwaardelijke toestelbevestiging. Open-/kliktracking is bewust uit. Staging kan geen daadwerkelijke ‘afgeleverd’-mailstatus tonen zonder een geconfigureerde SendGrid Event Webhook; de bestaande deployment meldt expliciet wanneer het gedeelde account geen vrij webhookslot heeft.

## Bewijs en resultaten

Gecontroleerd op 27 september 2026:

| Controle | Resultaat |
| --- | --- |
| `pnpm verify` | Geslaagd: 243 tests in 43 bestanden; lint, TypeScript, build en scan van 987 client/server-artifacts |
| Reset + volledige pgTAP-suite | Geslaagd: 1.343 checks in 53 bestanden |
| Database-lint | Geen nieuwe waarschuwingen; één bestaande ongebruikte variabele |
| Echte parallelle transacties | Alle achtvoudige publicatie-, edit-, claim- en campagneproeven geslaagd |
| Redactionele browserflow | 8 checks geslaagd: volledige flow en beperkte redacteurrechten op desktop, Android/Chromium, iPhone/WebKit en 320px/reduced motion |
| Bestaande authenticated-live | Alle 31 flows geslaagd, inclusief 320px en 200% tekst |
| Mobiele PWA | Beide flows geslaagd met een lokale publieke VAPID-testkey; geen externe push |
| Lighthouse 13, `/nieuws` | Toegankelijkheid 100, best practices 100, SEO 100; [rapport](lighthouse.json) |

De database- en browsersuites moeten na elkaar draaien: de bestaande authenticated tests muteren dezelfde seedaccounts, capabilities en groepsruns. CI draait de bestaande authenticated suite daarom met één worker; de expliciete concurrencyproeven blijven parallel. De extra publicatie-/verzendrechten zijn ook opgenomen in de bestaande grant/revoke-browsertest.

Screenshots staan onder `docs/screenshots/redactiekamer/` en bevatten uitsluitend fictieve lokale testinhoud. Voorbeelden:

- [Desktop Redactiekamer](../screenshots/redactiekamer/editorial-desktop-redactiekamer.png)
- [Desktop Nachtpostpreview](../screenshots/redactiekamer/editorial-desktop-nachtpost-preview.png)
- [Website nieuws](../screenshots/redactiekamer/editorial-desktop-website-nieuws.png)
- [Ouderfeed](../screenshots/redactiekamer/editorial-iphone-webkit-oudernieuws.png)
- [Mobiele pushvoorkeuren](../screenshots/redactiekamer/editorial-samsung-chrome-push-voorkeuren.png)
- [320px redactie](../screenshots/redactiekamer/editorial-narrow-redactiekamer.png)
