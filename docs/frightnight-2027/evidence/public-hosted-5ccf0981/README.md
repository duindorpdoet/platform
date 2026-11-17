Gepubliceerde publieke browseracceptatie: 5ccf0981

Deze controles zijn werkelijk uitgevoerd tegen `https://staging-halloween.duindorpdoet.nl` op release-SHA `5ccf09815ad4e923708b0adebd7fad5cf4de08e2`, na expliciete vrijgave en eigen controle van health, editie, omgeving, providerconfiguratie en serviceworkerbytes.

Alle 24 publieke browserproeven slagen in 26,6 seconden. Daaronder vallen zes schermbreedtes, toetsenbordbediening, rustige weergave en behoud daarvan, geen JavaScript, bruikbare publieke inhoud bij aanvullende database-uitval, het echte verhaal, voorwaarden, vier anonieme inloggrenzen en native PWA/offline/herstel. De aangescherpte regressie vereist dat het offline logo werkelijk laadt en decodeert, ook op de privéfallback met HTTP 503 en `private, no-store`.

Alle 19 aanvullende beeld- en PWA-controles slagen. Tien volledige screenshots tonen home, geopend verhaal, voorwaarden, ongebruikte inlogpagina en echte offline noodinformatie op 390 en 1440 pixels. Vóór iedere capture is door de pagina gescrold; alle zichtbare afbeeldingen waren volledig geladen, hadden een positieve natuurlijke breedte en zijn gedecodeerd. De native worker was actief, er was geen pushabonnement, de cache bevatte geen privépagina's of API-data en de echte reconnect werkte. Health vóór en na de ronde wees naar dezelfde gepubliceerde SHA.

Deze proeven waren uitsluitend anoniem en read-only. Formulierverzending, Auth/OTP, checkout, push, mail, muterende API-methoden en externe hosts waren geblokkeerd. Er zijn nul verboden pogingen en nul browserpaginafouten geregistreerd. Geen accounts of serverdata zijn gewijzigd.

`report.json` bevat de samenvatting en grenzen; de oorspronkelijke test- en visuele rapporten, bronbinding, SHA-256-manifest en exacte versies van de gecontroleerde testharness staan ernaast. Authenticated rollen, routes, betalingen, mail, belasting en retentie hebben eigen bewijs. Dit is geen fysieke Android/iOS-, camera- of hardwareclaim. Het mislukte 3fc-tussenbewijs blijft afzonderlijk bewaard.
