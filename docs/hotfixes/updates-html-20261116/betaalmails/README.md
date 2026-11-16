# Aangepaste betaalverzoeken voor productie 2026

Bron: door Danny aangeleverde `Halloween-2026-Aangepaste-Betaalmails.zip` (34.800 bytes), SHA-256 `e4cc605afb62c6cc5d2a3c6762215e7ebef6fbcfd6a2b16e352318aebaf15647`.

De inhoud is gecontroleerd als bronmateriaal. De twee volledige TypeScript-bestanden uit de ZIP zijn niet blind over de actuele bestanden geschreven: dat zou de aanvullende veilige HTML-ondersteuning voor Updates verwijderen. Alleen de nieuwe betaalverzoekdefinitie en de instelbare, geëscapete afsluitgroet zijn overgenomen. De afsluitgroet heeft tevens een niet-lege grens van 200 tekens.

De nieuwe tekst geldt uitsluitend voor `payment_link_ready` als beide serverconfiguratiewaarden exact overeenkomen: `APP_ENVIRONMENT=production` en `EVENT_SLUG=duindorp-halloween-2026`. Payloadvelden kunnen die keuze niet wijzigen. Bestaande servergevalideerde betaal-URL's, ontvangers en betaalprocessen blijven leidend. Een lege kinderlijst onderdrukt de gezinsdetails van een gezamenlijke betaling niet meer binnen deze nieuwe variant.

De vier HTML-/tekstparen onder `lib/mail/fixtures/halloween-2026/` zijn ongewijzigde voorbeelden uit de ZIP: kinderen, gezamenlijke betaling met en zonder aangewezen betaler, en instructie zonder externe betaallink. `lib/mail/payment-2026.test.ts` vergelijkt alle bytes met de echte renderer. De voorbeelden gebruiken fictieve gegevens en een `.invalid`-betaaladres. De proeven versturen niets.

`betaalverzoek-ingetrokken.html` en `.txt` zijn de afzonderlijke originele bestanden uit de ZIP. Het bestaande intrekken van een betaalverzoek kent geen bijbehorende automatische mailactie. Deze release voegt die actie niet toe; de bestanden blijven beschikbaar als los sjabloon. De aangeleverde tekst is geen opdracht om ontvangers te selecteren of berichten te verzenden.

Offline Chromiumcontrole van alle vijf HTML-bestanden op 390 en 1440 pixels: tien geslaagde controles, gedecodeerd bestaand logo, geen horizontale overloop en nul externe requests. Dit is geen bewijs van aflevering of weergave in Gmail, Outlook of Apple Mail. Er zijn geen echte OTP's, betalingsmutaties of e-mails uitgevoerd.
