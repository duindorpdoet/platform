# Opgeslagen markers en bevestiging van startpunten

Uitgangspunt: productie `ce23ab3564b6157ebfcb64c62d1edec4b11d0c8f`, gecontroleerd via `/api/health`. De reparatie staat op `codex/startregie-marker-readiness`, rechtstreeks vanaf deze productieversie. De andere werkmappen en de nog niet gepromoveerde avondrelease blijven behouden.

## Aangetoonde foutketen

`LocationEditor` beoordeelde alleen de aanwezigheid van coördinaten. `admin_location_marker_save` bewaarde de positie, maar kon zonder beschikbare wandelnode geen wandelkoppeling toevoegen. `admin_startregie_confirm_point` gaf ook dan `confirmed: true` terug, zonder een terugleesbare bevestigingsstatus voor die positie. De verse snapshot berekende `verified` vanuit de wandelkoppeling en de oude waarschuwing `MISSING_MARKER` vanuit ontbrekende coördinaten **of** een ontbrekende node. Daardoor kon een correct opgeslagen adrespositie toch als foutieve marker blijven verschijnen. Een werkelijk ontbrekende positie werd bovendien niet door de bevestigingsfunctie geweigerd.

De productie-inventaris van 24 oktober om 11:26 Nederlandse tijd bevatte twee startpunten, twintig groepen, één wandelnode en geen wandelverbindingen. Dit is een aantoonbare productievoorwaarde, geen bewijs van de afzonderlijke actuele recordwaarden. De originele screenshots bewijzen ook geen dubbele locatie. De nieuwe alleen-lezen inventaris legt de echte event-, startpunt- en poort-IDs, relaties, versies, positiebronnen en positievingerafdrukken vast zonder adressen, contactgegevens of credentials te loggen.

Daarnaast konden het algemene poortformulier en de kaarteditor verschillende posities gebruiken. Het poortformulier schreef adrescoördinaten terug over een bestaande handmatige marker. De kaarteditor kon na herinitialisatie een pin verliezen doordat een al bestaande `ready`-status niet veranderde. Bij het bewerken van een bestaande eindpoort werd de extra keuze voor een nieuwe eindpoort ook onterecht opnieuw verplicht.

## Gedrag na de reparatie

De serverhelper `routing_position` kiest en valideert een volledig paar: handmatige override, officiële adrespositie, historische adrespositie. Er worden nooit twee halve bronnen gecombineerd. De kaart, startpuntformulieren, snapshot, bevestiging en routepreview gebruiken deze projectie of equivalente regels achter de bestaande databasepaarcontroles. Ontbrekende of ongeldige waarden krijgen geen kaartcentrum als fallback in de opgeslagen projectie.

Een bewuste startpuntbevestiging legt via de bestaande auditstructuur actor, tijd, versie, bron en een vingerafdruk van de relevante locatie vast. Exact herhalen is veilig. Bestaande bevestigingen op de actuele versie blijven herkenbaar. Een wijziging van de relevante positie of verplichte eerste poort veroudert de bevestiging. Een adresgeocode naast een ongewijzigde handmatige routingpositie wist die bevestiging niet.

Locatiebevestiging maakt geen wandelnetwerk en deelt geen groepen in. De bestaande routevoorwaarden blijven servermatig gelden voor planning en groepsafspraken. Een ontbrekende wandelroute verschijnt als `WALKING_ROUTE_MISSING`, met uitleg dat de locatie zelf wel bevestigd kan worden. Een ongeldige verplichte eerste poort blijft een gerichte blokkade. Niet-gerelateerde poorten en nog niet ingedeelde groepen blokkeren de locatiebevestiging niet.

De kaart biedt **Deze marker bevestigen** bij de opgeslagen pin; Startpunten biedt **Startpunt bevestigen**. Na opslag staat duidelijk of deze inhoudelijke bevestiging nog nodig is. Een mislukte write sluit de editor niet, toont geen opslagsucces en houdt de invoer beschikbaar. De editor bewaart de versie waarmee hij geopend is. Vertraagde snapshots mogen geen nieuwere serverprojectie overschrijven. De marker blijft na herinitialisatie zichtbaar.

Het poortformulier bewaart een handmatige routingpositie bij gewone adres- of tekstbewerkingen. Een expliciete wijziging in de kaarteditor gaat transactioneel door dezelfde markeropslag. Een bestaande eindpoort hoeft bij een gewone bewerking niet opnieuw gekozen te worden. Onvolledige activatiegegevens krijgen een zichtbare herstelmelding. Verzoeken en busy-state zijn begrensd; afwijzen en opnieuw proberen zijn getest.

## Reproduceerbaar serverbewijs

`073_start_location_readiness.sql` bootst de ontbrekende wandelgrafiek na in een transactie op synthetische data. Vóór de reparatie faalden vier controles: bevestiging ontbreekt in de verse snapshot, onterechte markerwaarschuwing, geen afzonderlijke routemelding en foutief succes zonder positie.

| Synthetische entiteit | Opgeslagen bron | API/projectie | Bevestigingsvoorwaarde |
| --- | --- | --- | --- |
| Startpunt `20000000-0000-0000-0000-000000000001`, adrespositie, geen node/edges | Adres | Geldige locatie; route niet beschikbaar | Locatie bevestigen slaagt; geen groepsindeling |
| Hetzelfde ID na expliciete handmatige opslag | Handmatig | Verse snapshot leest exact het opgeslagen paar terug | Oude versie geweigerd; actuele versie bevestigt veilig |
| Hetzelfde ID zonder opgeslagen paar | Ontbrekend | `START_POINT_POSITION_MISSING` | Geen bevestiging; marker plaatsen en opslaan |
| Hetzelfde ID met verplichte eerste poort zonder positie | Geldige eigen positie | `LINKED_START_PORTAL_POSITION_INVALID` | De gekoppelde poortmarker herstellen |

De mobiele echte Auth/RPC-proeven staan in `tests/e2e/start-location.spec.ts`: beide gemelde locatielabels met afzonderlijke synthetische IDs, officiële positie, handmatige opslag, afwijzing/herhaling, hard herladen, tweede sessie, oude editor, vertraagde snapshot, poort toevoegen/bewerken en gewone bewerking van een bestaande eindpoort. [Mobiel bewijs van de opgeslagen en bevestigde handmatige pin](../ops/screenshots/start-marker-repaired-390.png).

De bestaande Startregieproeven toetsen daarnaast concept, groepsbevestiging, publicatie, ouderpayload vóór T−60 en mobiel fout-/focusgedrag. De volledige databasesuite omvat de bestaande publicatie-, privacy-, route-, credential-, betaling- en kindrelatiecontroles. Zie de release-PR voor de definitieve uitvoeringsresultaten en deploymentlinks.

## Gegevensbehoud en uitrol

De nieuwe migratie vervangt functies en voegt private helpers toe; ze wijzigt geen bestaande domeinrijen. Er is geen backfill, geocoding, reset, herindeling of datacorrectie nodig. Onzekere of ontbrekende posities vragen expliciete controle. Geen startafspraak wordt door deze uitrol bevestigd of gepubliceerd. De bestaande serverprojecties voor het eerste adres vanaf exact één uur vóór de eigen gepubliceerde starttijd blijven behouden.

Staging bevat al dertien migraties van een andere release. De productiehotfix neemt die niet mee. De bestaande stagingworkflow ondersteunt voor deze uitrol exact de hotfixbranch, met dezelfde versleutelde backup, geïsoleerde herstelproef, datavergelijking, echte stagingdeployment en mailacceptatie. Alleen de reeds geïnstalleerde stagingmigraties uit de vastgelegde broncommit worden voor de CLI-historie tijdelijk met gecontroleerde SHA-256 beschikbaar gemaakt; ze worden niet opnieuw uitgevoerd. Onbekende historie blijft een harde fout. De herstelproef voert uitsluitend ontbrekende gereviewde migraties uit en ondertekent de hashes van de volledige release.

Productie vereist nog steeds de volledig geslaagde stagingworkflow en deployment van exact dezelfde commit. Er is geen geforceerde verplaatsing van de stagingbranch en geen promotie van de andere featurecode. Een tijdelijke staging-environmentregel voor uitsluitend deze branch wordt na de uitrol verwijderd.

Terugval: gebruik de bestaande immutable applicatierelease-interface voor de vorige appversie. Laat de additieve private helpers en auditgeschiedenis behouden; oudere RPC-signaturen blijven bruikbaar. Herstel databasegegevens alleen met afzonderlijke toestemming en een vastgesteld herstelpunt. Verwijder geen publicaties, routes, aankomsten, QR-materiaal of kinderzegels.
