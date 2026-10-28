# Handmatige poorten in de actieve lijst

De productie-RPC `api.admin_portal_management_snapshot` gaf 17 actieve lijstregels terug bij 19 goedgekeurde poortrecords. P-38 en P-44 waren handmatig aangemaakt zonder `application_id`. De oorspronkelijke projectie gebruikte een inner join naar de bewonersaanvraag en sloeg beide records daardoor over.

De nieuwe wrapper behoudt de bestaande bevoegdheidscontrole en alle overige snapshotsecties. Alleen `activePortals` wordt opnieuw opgebouwd vanuit goedgekeurde poortrecords met lifecycle `approved` of `active`. De bewonersaanvraag is optioneel. Eigen contactvelden van de poort hebben voorrang, met de bestaande aanvraag-/intakevelden als fallback. Concepten, geregistreerde concepten en archieven blijven uitgesloten.

De migratie verandert geen poortgegevens. P-38 blijft actief/open en de aangewezen eindpoort; P-44 blijft goedgekeurd/in voorbereiding. Er worden geen openingstijden, eigenaren, uitnodigingen of mails gewijzigd. Voor uitrol zijn afzonderlijke inhoudshashes van beide poorten, hun locaties en tijdvakken vastgelegd; de nacontrole vergelijkt deze met dezelfde records en controleert de echte geautoriseerde RPC.

Validatie: `pnpm verify` slaagt met 639 unittests en één bestaande skip; database-lint voor `api` en `app_private` bevat geen fouten; alle 2.512 pgTAP-asserties in 99 bestanden slagen, waarvan 27 nieuwe projectiecontroles. De browsertest voor handmatige poortidentiteit gebruikt nu daadwerkelijk een ontbrekende bewonersaanvraag en controleert zichtbaarheid, eigen contactnaam, voorbereiding en behoud van het nummer bij activering/bewerking. Anonieme gebruikers en deelnemers zonder beheerrechten krijgen geen toegang tot de contactprojectie.

Uitrol volgt de bestaande route via volledige CI, versleutelde backup met herstelproef, staging en vervolgens dezelfde revision naar productie. Mailtest-uitzonderingen blijven gebonden aan de daarvoor verleende toestemming; overige releasecontroles blijven verplicht.
