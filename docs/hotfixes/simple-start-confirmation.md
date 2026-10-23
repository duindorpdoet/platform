# Startpunt met één bevestiging

De oude `admin_startregie_verify_point`-route vereiste nog een fysieke loopcontrole, een aanloopinstructie en een koppeling binnen 75 meter. Bestaande startpunten konden daardoor een ander formulier tonen dan de ja/nee-keuze bij Poorten. De gebruiker heeft op 24 oktober 2026 expliciet om eenvoudig bevestigen gevraagd.

Beide Startregie-schermen tonen nu **Startpunt bevestigen**. `api.admin_startregie_confirm_point(event_slug,point_id,expected_version)` legt de organisatorische keuze en de werkelijke actor vast. De bestaande wandelgrafiek wordt automatisch gebruikt. Er wordt geen fysieke inspectie vastgelegd. Een herhaalde bevestiging zonder gewijzigde locatie behoudt de puntversie. Het oude RPC-signatuur blijft bruikbaar voor bestaande browserpagina's.

De knop vereist geen checklist, aanlooptekst of afstandscontrole. De planner gebruikt nog steeds de werkelijk aanwezige locatie- en routegegevens. Een ontbrekend adres of ontbrekende routegrafiek wordt niet verzonnen. Bestaande publicaties blijven ongewijzigd; de migratie voert geen gegevenswijziging uit buiten de expliciet aangeroepen opdracht.

Lokaal uitgevoerd op de geïsoleerde stack `duindorp-ops-codex-20261023`:

- Schone reset van alle migraties en fixtures; 1.907 pgTAP-tests in 72 bestanden geslaagd.
- 355 applicatietests, lint, typecheck en productiebuild geslaagd.
- Drie bestaande echte Auth/RPC-browserproeven geslaagd, inclusief publicatie en mobiel toetsenbordgebruik.
- Eén extra browserproef met een nieuw startpunt zonder inspectieformulier: bevestiging via één knop op 390px, echte RPC 200, routegegevens daarna beschikbaar. Screenshot: `docs/ops/screenshots/start-simple-confirmation-390.png`.
- Database-advisor: alleen de bestaande waarschuwing voor `pg_net` in `public`; geen nieuw probleem voor deze functies. Bestaande SQL-lintwaarschuwingen zijn ongewijzigd.

De uitrol gebruikt de bestaande staging-, back-up/herstel- en productiecontroles. De aanvullende `readonly_baseline`-workflow heeft uitsluitend SELECT-opdrachten, draait alleen op de productiebranch onder het bestaande productie-environment en sluit deployment bij die modus uit. Dit ondersteunt de aparte, lopende opdracht voor de avondverbeteringen.

Herstel: zet de vorige UI-release terug. De nieuwe functie kan blijven bestaan; oudere aanroepen blijven werken. Verwijder geen publicaties, registraties, aankomsten of QR-materiaal. De migratie is herhaalbaar en staat expliciet in de gereviewde releaselijst.
