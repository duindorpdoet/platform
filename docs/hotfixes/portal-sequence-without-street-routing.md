# Poortvolgorde zonder verplichte straatrouting

Uitgangspunt is de werkelijk gedeployde productiecommit `79783e35232dffdd9d016f80d2ee961e4f250519`, met migratie `20261024145517`. Deze wijziging bouwt daarop voort en neemt de andere stagingrelease niet mee.

## Aangetoonde oorzaak

De eerdere markerreparatie scheidde locatiebevestiging van wandelgereedheid, maar behield die laatste als voorwaarde voor de groepsplanning. Dat past niet bij de verduidelijkte productafspraak: een route is de volgorde van bestemmingen, geen wandelpad.

Vier echte pgTAP-proeven faalden op de oude functies: een geldig bevestigd punt was niet beschikbaar voor indeling, `api.admin_startregie_move_group` gaf `START_POINT_NOT_VERIFIED`, geschikte huizen verdwenen uit de automatische preview en de snapshot bleef `WALKING_ROUTE_MISSING` tonen. Het voor/na-bewijs gebruikt synthetische gegevens en wordt aan de werkelijke database-/RPC-grens uitgevoerd.

De productie-inventaris van 25 oktober 00:41 UTC identificeerde:

| Startpunt | ID | Gekoppelde poort | Opgeslagen bron | Actuele versie / bevestigingsaudit |
| --- | --- | --- | --- | --- |
| Horror Zone / publiekslabel Horor zone | `c5333776-9738-407f-b749-a8d6b41662fa` | `2d78c7a8-bc11-4fcc-8af0-b458cb6214a8` | Adres | 12 / 12 |
| Welcome to the Freakshow | `073dd9a5-8ef5-4677-841d-2a390fddd446` | `6484e115-95c9-4494-9e56-0db8aca58349` | Handmatig | 1 / 1 |

Beide hadden geldige posities, actuele bevestigingen en geldige gekoppelde poorten, maar geen wandelnode. Er waren twintig niet-ingedeelde groepen, één node en nul goedgekeurde verbindingen. Dit zijn gegevens uit een begrensde alleen-lezen inventaris; geen coördinaten, adressen, accounts of credentials worden hier gekopieerd.

## Gewijzigde voorwaarden

`portal_location` gebruikt hetzelfde volledige-paarcontract als `start_point_location` en `routing_position`. `portal_location_ready` controleert het opgeslagen adres en de effectieve positie. `start_point_destination_ready` controleert het actieve startpunt, adres/positie en werkelijk vereiste gekoppelde eerste poort. De oude interne naam `start_point_safe_connection` blijft als compatibiliteitsaanroeper bestaan, met bestemminggereedheid als betekenis. Een aparte bevestigingsaudit blijft apart zichtbaar; er wordt geen algemene verificatievlag gevuld.

De expliciete functievervangingen behouden de bestaande autorisatie, evenementrelaties, locks, versies, betalingen, vensters en capaciteit:

- `api.admin_startregie_start_point_from_portal`: selecteert een geldige opgeslagen huislocatie zonder de oude wandelverificatievoorwaarde.
- `api.admin_startregie_confirm_point`: bevestigt uitsluitend de opgeslagen locatie en verandert geen wandelknoop.
- `api.admin_startregie_slots_prepare`, `api.admin_start_slot_save`, `api.admin_startregie_move_group` en `start_point_ready_at`: geldige bestemmingen en tijdvensters vervangen verplichte knopen/verbindingen.
- `api.admin_save_route_settings`: de eindpoort vereist een geldige locatie, geen wandelnode.
- `api.admin_start_point_save`: een bewust opgegeven optionele node blijft aan het juiste evenement gebonden; zij is niet verplicht om de locatie te bevestigen.
- `validate_route_plan_stop` en `api.run_start`: ook bestaande statische plannen blijven bruikbaar zonder een straatgraaf; echte ongeschikte bestemmingen blijven geweigerd.
- `start_ops_route_preview` en `dispatch_next_stop_before_visit_preference`: behouden de bestaande automatische selectie, spreiding, voorkeuren, vensters, bezoekgrens, finale- en reserveringsregels, met markerposities als geografische bron.
- `api.admin_startregie_snapshot`: alleen de niet-toepasselijke netwerkmelding verdwijnt. Ontbrekende adressen/markers en niet-ingedeelde groepen blijven eigen herstelpunten.
- `start_ops_route_revision`: optionele graafverbindingen vormen geen routevoorwaarde; wijzigingen in de kandidatenpool blijven zichtbaar als een nieuwe revisie.

Het geavanceerde bevestigingspad stuurt bovendien geen niet-bestaand `_reason`-argument meer naar `admin_startregie_confirm_starts`. Het gebruikt de geselecteerde afspraken en hun echte servervoorwaarden, in plaats van alle algemene waarschuwingen als universele blokkade te gebruiken.

De optionele graafdata, `walking_path_metrics`, `portal_has_verified_walking_connection` en onderhoudsfuncties blijven behouden. Zij bepalen deze gebruikersflow niet en hun velden worden niet kunstmatig goedgekeurd. De verplichte wandelkoppelingbediening is uit Startregie verwijderd.

## Schatting en beperkingen

`destination_estimate` geeft de hemelsbrede afstand terug. Voor de planningsschatting gebruikt zij 35% afstandstoeslag en 1,1 m/s, met minimaal één minuut per verplaatsing. Bezoekduur en buffers blijven de bestaande configureerbare waarden. Ontbrekende of ongeldige posities leveren geen schattingsrij op, dus ook geen stille nul minuten.

Dit is geen bewezen loopafstand, toegankelijk wandelpad of afslagbegeleiding. De preview noemt afstand hemelsbreed en reistijd geschat. Gelijke afgeronde reistijden worden met afstand en record-ID onderscheiden. Werkelijke vensters, fysiek te kleine huizen, gesloten/niet-goedgekeurde poorten en de gereserveerde finale blijven bepalend. Er is geen nieuwe providerintegratie; een directionsprovider wordt niet aangeroepen.

## Gegevens, privacy en aankomst

De migratie vervangt uitsluitend functies en voegt private helpers toe. Geen reset, backfill, herindeling, markerverplaatsing, QR-rotatie of datacorrectie is nodig. Bestaande publicaties worden niet herschreven of opnieuw gepubliceerd. De huidige vrijgegeven stop en eerder bevestigde bezoeken blijven intact; nieuwe huizen veranderen uitsluitend het kandidaatrestant.

`published_start_projection` en de serverprojecties voor deelnemers blijven ongewijzigd: eigen starttijd vooraf, eerste adres en marker vanaf exact T−60. De deelnemerskaart gebruikt alleen de actuele vrijgegeven bestemming. De volledige preview en kandidatenpool blijven privé voor beheer.

De bestaande QR-/korte-codeaankomst blijft de enige aanleiding voor een werkelijk bezoek, inclusief één zegel per aanwezig kind dat buiten blijft. Een pending/offline opdracht behoudt run, stop, versie en idempotentiesleutel; er wordt geen volgende bestemming vrijgegeven vóór serverbevestiging. De bestaande receipt- en transactieregeling blijft behouden.

## Verificatie en uitrol

De nieuwe serverproeven staan in `074_portal_sequence_without_street_routing.sql` en `075_no_street_arrival_sequence.sql`. Zij testen indeling, bevestiging, automatische privévolgorde, expliciete publicatie, vroege eigen starttijd/T−60, echte aankomst, twee buitenblijvende aanwezige kinderen, retry, nieuwe huizen en behoud van huidige stop/publicatie zonder goedgekeurde graafdata. Bestaande regressies voor oude routes, capaciteit, finale en privacy blijven deel van de volledige suite.

`tests/e2e/portal-sequence.spec.ts` gebruikt echte lokale Auth en RPCs op 390 px: marker bevestigen, groep/tijd opslaan, afspraak bevestigen, privévolgorde openen, expliciet publiceren, herladen/tweede sessie, starten en via de echte codeflow door naar precies één volgende marker. Een vertraagde aankomst en gelijktijdige retries controleren dat de volgende bestemming pas na serverbevestiging verschijnt. Directionsaanroepen zouden HTTP 503 krijgen; de flow heeft ze niet nodig.

Lokaal geverifieerd: 1.992 databasecontroles in 75 bestanden, 367 applicatietests, lint/typecheck, productiebouw en scan van 1.041 clientartefacten. De echte parallelle indelings-/publicatieproef en alle zeven bestaande Startregie-/poortbrowserproeven slagen. De extra mobiele beheer-/deelnemersketen slaagt met precies één zichtbare kaartmarker vóór en na de aankomst, zonder directionsaanroepen.

Synthetisch mobiel bewijs: [beheerpreview](../ops/screenshots/sequence-admin-390.png), [eerste vrijgegeven bestemming](../ops/screenshots/sequence-current-390.png), [volgende bestemming na bevestiging](../ops/screenshots/sequence-next-390.png).

Definitieve CI-, staging-, productie- en backupbewijzen worden in de release-PR vastgelegd. Productie wordt pas als bijgewerkt gemeld nadat de bestaande exacte-commitprocedure slaagt en externe health dezelfde commit teruggeeft. De afgeschermde alleen-lezen inventaris gebruikt uitsluitend tabelgegevens, zonder private functierechten te verruimen.

Terugval gebeurt via de bestaande immutable releasemethode en zo nodig een gereviewde functieherstelmigratie. Een oudere app/functieversie kan de oude graafverwachting terugbrengen. Er is geen aanleiding om domeinrijen of historische bezoeken terug te zetten. Een gegevensherstel blijft een afzonderlijke, expliciet begrensde handeling.
