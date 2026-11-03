# Verlopen lokale 2026-fixtures

De eerste echte [PR-CI-run 41569583125](https://github.com/duindorpdoet/platform/actions/runs/41569583125) op `7bd44ad80bdbc56e904df07e807c4ea6c0ed0a75` slaagde voor applicatievalidatie en de zestien nieuwe publieke browserproeven. De volledige databasepoort faalde op 24 bestaande testbestanden. De nieuwe FrightNight-contracten waren niet de oorzaak: de lokale seed-QR's verliepen op 1 november 2026 en verschillende proeven veronderstelden dat de echte serverklok nog vóór 31 oktober stond.

Alle aanpassingen staan uitsluitend in `supabase/seed.sql`, lokale SQL-tests en twee testincludes. Geen bestaande runtimefunctie, tijdscontrole, databaseconstraint, RLS-regel of releasepoort is versoepeld.

- Seed-QR's blijven op iedere nieuwe lokale opbouw nog 365 dagen geldig. Hun echte geldigheidscontrole blijft actief.
- Voor adresvrijgaveproeven wordt een nieuwe synthetische toekomstige afspraak toegevoegd. Bestaande immutable publicaties worden niet gewijzigd of verwijderd.
- Kalenderproeven schuiven hun lokale evenement en alle relevante invoer/verwachtingen naar twee kalenderjaren na het huidige jaar. De API gebruikt zijn echte klok. De proeven op T−61/T−60, vroeg starten, capaciteit, finale, replay en gepubliceerde onveranderlijkheid blijven behouden.
- Proeven met al bestaande relatieve start-/openingsvensters krijgen binnen hun rollbacktransactie dezelfde lokale evenementdag. De DST-parserproeven behouden hun historische exacte datums.
- De countdownproef controleert nu zowel een relatieve geldige periode als een aantoonbaar verlopen kaart.

Alle 24 aanvankelijk falende bestanden zijn daarna lokaal opnieuw geslaagd; het [brongebonden rapport](validation/legacy-fixture-drift-report.json) bevat aantallen, bestanden en hashes. De lokale harness gebruikt uitsluitend gecontroleerde synthetische data: zeventien `.invalid`-accounts en negen huishoudens met exacte seedlabels en seed-ID's. De bronkopie bevat nul legacy-outboxregels, mailgebeurtenissen en mailworkerconfiguraties. Er is geen bestaande QA-database, stagingrecord of productiegegeven gewijzigd.

Dit is geen vervanging voor de schone Supabase-CLI-CI. De aanvullende lokale poging over alle 133 SQL-bestanden had 19 harnessfouten door ontbrekende Cron-/Vault-/uitnodigingsinfrastructuur, migratiehistorie en een lokaal verhoogde seedcounter; die worden niet als geslaagd geclaimd en niet met bronwijzigingen gemaskeerd. Die bestanden slaagden in de eerste echte CI. De definitieve nieuwe PR-head moet opnieuw de volledige oorspronkelijke databasepoort doorlopen voordat staging mag worden bijgewerkt.
