# Aangepaste betaalverzoeken voor productie 2026

Bron: door Danny aangeleverde `Halloween-2026-Aangepaste-Betaalmails.zip` (34.800 bytes), SHA-256 `e4cc605afb62c6cc5d2a3c6762215e7ebef6fbcfd6a2b16e352318aebaf15647`.

De inhoud is gecontroleerd als bronmateriaal. De twee volledige TypeScript-bestanden uit de ZIP zijn niet blind over de actuele bestanden geschreven: dat zou de aanvullende veilige HTML-ondersteuning voor Updates verwijderen. Alleen de nieuwe betaalverzoekdefinitie en de instelbare, geëscapete afsluitgroet zijn overgenomen. De afsluitgroet heeft tevens een niet-lege grens van 200 tekens.

De nieuwe tekst geldt uitsluitend voor `payment_link_ready` als beide serverconfiguratiewaarden exact overeenkomen: `APP_ENVIRONMENT=production` en `EVENT_SLUG=duindorp-halloween-2026`. Payloadvelden kunnen die keuze niet wijzigen. Bestaande servergevalideerde betaal-URL's, ontvangers en betaalprocessen blijven leidend. Een lege kinderlijst onderdrukt de gezinsdetails van een gezamenlijke betaling niet meer binnen deze nieuwe variant.

De vier HTML-/tekstparen onder `lib/mail/fixtures/halloween-2026/` zijn ongewijzigde voorbeelden uit de ZIP: kinderen, gezamenlijke betaling met en zonder aangewezen betaler, en instructie zonder externe betaallink. `lib/mail/payment-2026.test.ts` vergelijkt alle bytes met de echte renderer. De voorbeelden gebruiken fictieve gegevens en een `.invalid`-betaaladres. De proeven versturen niets.

`betaalverzoek-ingetrokken.html` en `.txt` zijn de afzonderlijke originele bestanden uit de ZIP. Danny heeft gekozen voor een kopieerbaar sjabloon in Updates. De drie inhoudelijke alinea's zijn daar voor editie 2026 beschikbaar als selecteerbare HTML en als concept; de bestaande update-mail voegt zelf de vaste afsluiting en contactgegevens toe. Een bestaand concept wordt alleen na bevestiging vervangen; doelgroep, prioriteit en mailkeuze veranderen niet. Er wordt niets gepubliceerd of ingetrokken door het sjabloon te openen of te gebruiken.

Updates richt zich op rollen en heeft geen individueel betaalstatusfilter. Publiceer deze tekst alleen als het eerdere betaalverzoek daadwerkelijk voor iedereen in de gekozen doelgroep is ingetrokken. Het bestaande intrekken van een betaalverzoek krijgt geen automatische mailactie; de aangeleverde tekst selecteert geen ontvangers en verstuurt geen berichten.

Offline Chromiumcontrole van alle vijf HTML-bestanden op 390 en 1440 pixels: tien geslaagde controles, gedecodeerd bestaand logo, geen horizontale overloop en nul externe requests. Dit is geen bewijs van aflevering of weergave in Gmail, Outlook of Apple Mail. Er zijn geen echte OTP's, betalingsmutaties of e-mails uitgevoerd.
