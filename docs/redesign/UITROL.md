# Migratie, staging en terugval

Status: voorbereid; **niet uitgevoerd op echte staging of productie**. Productie-uitrol vereist het afgesproken akkoord en geldige projectautorisatie. De huidige GitHub-stagingworkflow voert `supabase db push` uit na een merge naar staging. Merge deze draft daarom pas na de backup-/herstelpoort hieronder.

## 1. Vooraf vastleggen

Verifieer opnieuw health-SHA, Git-ref en Supabase-projectidentiteit; de basis bij aanvang was `bc2b3796d39f79f7f6dc5ef5bd4978a304eb125b`. Lees werkelijk toegepaste migraties uit `supabase_migrations.schema_migrations`, inspecteer actuele RPC-definities, triggers, RLS/policies/grants, Auth-, Storage- en eventconfiguratie. Vergelijk die met de repository. Bij drift eerst een gericht compatibiliteitsplan, geen force/reset.

Inventariseer stabiele relaties en IDs van events, registraties, kinderen, huishoudens, samenlopen, groepen, publicaties, routes/stops, poorten, bezoeken, zegels, stemmen en media. Neem betaalbedragen/statussen/externe referenties, geldige credentialrevisies en bestaande sessies mee. Leg registratie-/publicatiestanden, start-/stoptijden, portaloperatie, featureflags, buckets en objectverwijzingen afzonderlijk vast. Geen geheime waarden in het reviewrapport.

`scripts/acceptance/redesign-inventory.py` is hiervoor een aanvullende alleen-lezen vingerafdrukcontrole. Gebruik een privé libpq-serviceconfiguratie met de bestaande bevoegdheid; geen wachtwoord of URL als argument:

```sh
PGSERVICE=halloween-audit python3 scripts/acceptance/redesign-inventory.py --output /secure/halloween/pre.json
PGSERVICE=halloween-audit python3 scripts/acceptance/redesign-inventory.py --baseline /secure/halloween/pre.json --output /secure/halloween/post.json
```

De tool gebruikt een repeatable-read, read-only datatransactie, een locklimiet van drie seconden en een querylimiet van vijf minuten. Hij bewaart alleen aantallen, kolomnamen, RLS-vlaggen en SHA256-vingerafdrukken; complete rijen binden IDs en relaties aan elkaar. Een baselinevergelijking projecteert bestaande kolommen, zodat een veilige nieuwe kolom geen schijnverschil geeft. Ontbrekende tabellen/kolommen of gewijzigde bestaande rijen blokkeren de vergelijking. Nieuwe tabellen en kolommen worden apart vermeld. De voorafgaande cataloguslezing is een afzonderlijke verbinding: voer dit uit in een beheerd venster zonder gelijktijdige DDL.

Deze tool vervangt geen backup, objectkopie, volledige RLS-audit of financiële reconciliatie. Hij kan bij grote tabellen sorteer-/I/O-belasting veroorzaken; meet op de herstelde kopie voordat hij live draait. Lokale proef: 142 synthetische tabellen; nul wijzigingen na herhaling van de vier migraties. Die uitkomst zegt niets over aantallen of integriteit van het live project.

## 2. Backup en herstelpoort

Maak met bestaande beveiligde infrastructuur een consistente databasebackup, inclusief benodigde Auth-gegevens, rollen/grants, schema's en historie. Versleutel de stroom vóór duurzame opslag, met een goedgekeurde publieke ontvangerssleutel; bewaar de ontsleutelsleutel elders. Een bruikbaar patroon voor een bevoegde operator met bestaande libpq-service en geïnstalleerde `age` is:

```sh
set -euo pipefail
umask 077
pg_dump --dbname=service=halloween-backup --format=custom | age --recipient "$BACKUP_RECIPIENT" --output /secure/halloween/database.dump.age
```

Dit patroon is niet hier als productiebackup uitgevoerd. Gebruik een passende PostgreSQL-versie en de providerafspraken voor Supabase-beheerde schema's. Geen plaintext-dump in Git, Actions-artifacts of gewone logs. Kopieer ook benodigde storage-objectbytes met versleuteling en een consistente objectmanifest/checksum; een dump van `storage.objects` bevat die bytes niet. Leg provider-/Auth-/scheduler-/featureconfiguratie en bijbehorende veilige herstelprocedure vast.

Herstel naar een aantoonbaar afzonderlijk project/database met uitgeschakelde uitgaande mail, push, cron en callbacks. Gebruik geen productieconnectoren in de herstelde omgeving. Bewijs aantallen, IDs, relaties, betaalreconciliatie en objectchecksums; test representatieve oude sessies en QR-credentials volgens de providergrenzen. Bewaar backup-ID, encryptie-/checksumbevestiging, hersteldoel, tijden, rapport en verantwoordelijke in privé beheeropslag. Alleen een dumpcommando of een providerbadge is onvoldoende herstelbewijs.

## 3. Expand en droge migratie

| Migratie | Toevoeging / compatibiliteit |
| --- | --- |
| `20261023014941` | Historische aankomstfeiten, nullable `departure_reason`, geautoriseerde aankomst-/vertrekcommando's; bestaande routecontracten en `all_skipped` behouden; bestaande Poortenboek-trigger aangepast; bestaande codesnapshot-wrapper behouden |
| `20261023014942` | Private dagbevestigingen, volwassen-/kindertutorials, gelezen hoofdstukken, bedankjes en versleuteld printmateriaal; alleen veilige bestaande sessie-/boekuitbreiding; publieke eventtijden uit configuratie |
| `20261023020159` | Geautoriseerde Generale-functie; eigen fixture-event en echte domeincommando's in teruggedraaide subtransactie; geen blijvende oefenrijen |
| `20261023021247` | Service-only preview en begrensde, expliciet geselecteerde historische backfill; installatie voert geen backfill uit |

Nieuwe tabellen hebben RLS en geen rechtstreekse clientwrites; aankomstfeiten zijn uniek per stop/deelnemer, bedankjes per event/huishouden/poort. Nieuwe private gegevens beginnen leeg; een bestaande deelname of credential wordt niet naar demo-instellingen geconverteerd. Hash-only posters worden als legacy gemeld en blijven geldig. Herdownloadbaar materiaal ontstaat alleen bij een bevoegde, expliciete vernieuwing. Printencryptie gebruikt een apart afgeleide sleutel van de bestaande serverkey; behoud die sleutel en documenteer keyrotatie vóór gebruik.

Pas op de herstelde kopie de migraties in volgorde toe via het bestaande versiebeheer. Meet duur, lockwachttijd, queryplannen en invloed op gelijktijdige routeacties. Stel een korte lock-timeout en begrensde statement-timeout in de daadwerkelijke migratieverbinding in; verifieer dat de gekozen runner die instellingen gebruikt. Een ALTER TABLE neemt kort een exclusieve lock, ook met een nullable kolom. Nieuwe indexes/tablecreaties en functie-/triggervervanging zijn niet bewezen lockvrij. De echte maximale looptijd/locktijd is nog onbekend en blokkeert live vrijgave tot die gemeten is.

Voer eerst alleen `api.redesign_arrival_backfill(actor, event_slug)` als bevoegde service uit. Bewaar het kandidaten-/uitzonderingsrapport privé. Ontbrekende scan, systeemoverslag, onzekere aanwezigheid/vertrektijd of gewijzigde historische teamcontext worden niet gegokt. Huidig groepslidmaatschap alleen is geen bewijs. Selecteer na beoordeling maximaal 100 stop-IDs per batch, leg reden/reviewer vast en pas alleen die batch toe. Herhaling voegt geen dubbele aankomst/zegel toe. Vergelijk ook eventuele hoofdstuk-/journey-afleidingen apart. Verklaar iedere goedgekeurde nieuwe rij; iedere andere wijziging blokkeert.

De lokale test bewijst SQL-herhaalbaarheid en fixturecontracten. Een representatieve eerste migratie-/backfillduur, live kandidaatenaantallen, legacy-excepties en echte financiële-/storagevergelijking zijn **nog niet gemeten**.

## 4. Stagingacceptatie

Gebruik passende toegangsbescherming en geschoonde representatieve gegevens, met bestaande testontvangerafscherming. Houd productie-IDs/relaties in de private vergelijking consistent; verzend geen echte deelnemersberichten. Voer de bestaande CI, Supabase-migratie-/RLS-/Auth-/concurrencychecks en alle 66 regels uit `acceptance.csv` uit. Voeg echte gelijktijdige arrival/vertrek/rotatieproeven toe; opeenvolgende idempotentietests alleen bewijzen geen concurrerende telefoons.

Maak per hoofdomgeving en belangrijke dialoog passende desktop-/mobiele captures, los de fontafwijking op, controleer toetsenbord/focus/zoom/safe areas/reduced motion. Controleer oude QR's/sessies en beide poster-PDF's. Oefen offline/reload/commit-zonder-antwoord met echte services en gecontroleerde telefoon. Test zwart-witpapier, camera en iOS/Android/PWA apart.

Registreer pas daarna de exact gedeployde en geteste staging-SHA met datum, configuratievingerafdruk en bewijslinks. Die SHA bestaat voor deze wijziging nog niet. Een groen lokaal rapport mag dit veld niet invullen.

## 5. Productie en terugval

Na inhoudelijke acceptatie en expliciet akkoord: controleer opnieuw de actuele basis, geldige backup/hersteltest, nulmeting en configuratie; voer de geteste expand-stappen uit, vergelijk data en stel pas de passende appversie beschikbaar. Geen resets, seeds, bulkvervanging of massale credentialrotatie. Houd veranderde toestanden na vrijgave traceerbaar.

App-rollback verwijdert de additieve tabellen/kolom niet. De oude app kan de uitgebreide snapshotvelden negeren, maar serverregels voor inclusieve aankomst blijven van kracht; oude UI die zonder scan wil afronden ontvangt `SCAN_REQUIRED`. Test deze combinatie vóór vrijgave. Bij onbruikbaarheid: houd de nieuwe, geteste serverregels en bied een gerichte compatibiliteitsfix of gecontroleerde operationele pauze; zet niet blind oude SQL-triggers terug die inclusieve zegels overslaan.

Bewaar nieuwe aankomstfeiten, vertrek, bedankjes, betalingen en ontvangstbewijzen. Herstel na ontvangst van echte transacties geen oude volledige backup als automatische rollback: reconcileer nieuw ontstane transacties vanuit append-only feiten/audit/receipts en pas gericht herstel toe. Een noodherstel vereist een afzonderlijk incidentplan met expliciet behoud van die mutaties en controle van externe betaal-/berichtreferenties. De uitvoerbare providerherstel- en rollbackproef staat nog open.
