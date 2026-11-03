Lokale browserproef van de editie- en rungebonden contract-sandbox

Build `0umM3p5GQp-3HD2l5F-x1` is werkelijk via HTTP op beide lokale standalone-processen gecontroleerd. De drie rapporten bewijzen samen 42 controles en bevatten 18 volledige screenshots op 390 en 1440 pixels.

- `configured-contract`: 18 controles bij globale contractconfiguratie.
- `mollie-armed-contract`: dezelfde 18 controles bij globale Mollie-configuratie zonder Mollie-sleutel. De expliciet geactiveerde eigen testkopie gebruikt uitsluitend haar vastgelegde contractadapter.
- `mollie-unarmed-no-key`: 6 controles in een andere eigen kopie. De echte checkout toont de ontbrekende configuratie, blijft onbetaald en bewaart de Mollie-providerbinding. Omzetting naar een sandbox wordt geweigerd.

De positieve scenario's gebruiken het echte formulier, toetsenbordbevestiging, actuele serveraantallen, een deelnemerscheckout, gesimuleerde betaalbevestiging en de regie-refundactie. Na reset blokkeert de verouderde runbinding betalingen tot een nieuwe expliciete bevestiging. Browseropslag wordt gewist om te controleren dat de server het beleid bewaart.

Een uitsluitend lokale preload registreert alle native server-fetches en blokkeert externe hosts. Alle drie scenario's registreerden toegestane lokale requests en nul externe pogingen. Geen OTP, Auth-creatie, externe PSP, mail of push is uitgevoerd. De gebruikte lokale beheerder is aantoonbaar synthetisch; uitsluitend een nieuwe, eigen synthetische seedinschrijving kreeg diens eigendom. Alle eigen kopieën zijn gearchiveerd en gesloten met behoud van financiële historie. De positieve rapporten vergelijken bovendien alle andere edities, financiële records, Auth-ID's en de inhoud van de legacy-mailoutbox.

Dit is geen gepubliceerde staging-acceptatie of bewezen Mollie-verbinding. Exacte tijden, bronhashen, helperhashen, netwerkwaarnemingen en beperkingen staan in `provenance.json` en de afzonderlijke rapporten.
