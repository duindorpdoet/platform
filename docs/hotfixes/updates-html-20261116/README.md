# Updates met HTML: lokale browserbeelden

Vastgelegd op 16 november 2026 met echte Chromium-screenshots, met uitsluitend generieke testtekst. De vier JPG-bestanden zijn samen 365.974 bytes. `screenshots.json` bevat tijdstip, bronhashen, afbeeldingsdecodering, formaten en de begrenzing van de proef.

- `admin-harness-1440.jpg` en `admin-harness-390.jpg`: de daadwerkelijke `ParticipantUpdates`-component en gedeelde veilige renderer, in een lokale Vite-componentharness met bestaande productie-CSS. De harness toont de bestaande CSS rechtstreeks; Tailwind-imports en utility-preprocessing zijn niet onderdeel van deze componentproef. De publicatie-RPC is een expliciete testfixture.
- `mail-preview-1440.jpg` en `mail-preview-390.jpg`: de lokaal gegenereerde HTML uit `/dev/shm/updates-html-mail-proof/update.html` in een offline browsercontext. Dit is geen test in Gmail, Outlook of Apple Mail en er is geen e-mail verstuurd.

Alle gebruikte logo's komen uit de lokale export van het bestaande productiebeeld. De bytes zijn gelijk aan `outputs/2026-11-16-betaaltemplates/assets/logo.webp` (SHA-256 `88efc6d8834bd931238dd423ae20070cf25f3686547bc9014b4d06fba5bba8be`). Browserrequests voor dit logo zijn lokaal beantwoord. Andere externe requests en alle muterende requests zijn geblokkeerd; geen van beide is aangetroffen. Er zijn geen accounts, persoonsgegevens of productiemutaties gebruikt.

De zes permanente componentproeven in `tests/participant-updates/updates.spec.ts` zijn uitgevoerd en groen: Enter/lege regels en toetsenbordpreview; HTML/XSS en gedecodeerde brede afbeelding op 390px; HTTPS/alt-invoer en escaping; inhoudslimiet en lege actieve HTML; oorspronkelijke RPC met bevestiging en e-mail uit; bestaande verplichte e-mailkeuze bij belangrijke updates. De mobiele proef controleert ook leesbare afmetingen van beide previewknoppen.

De XSS-proef bevat ook de CDATA-invoer uit het primaire [GHSA-2rjc-9xvg-45j7-advies](https://github.com/apostrophecms/apostrophe/security/advisories/GHSA-2rjc-9xvg-45j7), voor `noscript`, `style`, `textarea`, `script` en `xmp`. In de echte browser blijft alleen de veilige tekst over: geen verborgen link of afbeelding in de DOM en nul requestpogingen naar het verborgen afbeeldings-/linkdomein. Dit test de gerichte inputnormalisatie in de gedeelde renderer; de bestaande afhankelijkhedencontrole is behouden.

Alle vier beelden zijn visueel gecontroleerd. Dit bewijs betreft de lokale component- en mailweergave; deployment, echte accounts, e-mailbezorging en afzonderlijke mailclients vallen erbuiten.
