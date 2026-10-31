# Database- en herstelbewijs

De bestaande app is uitgebreid op basis van `db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`. Geteste codecommit: `c6288a8781c7896303bed1bdeabf0b8f87ae52af`. Alle 133 migraties en 474 pgTAP-controles in 13 bestanden slagen; `summary.json` bindt iedere geteste migratie aan zijn SHA-256. Dit is een lokale softwareproef met synthetische gegevens. Productie is uitsluitend gelezen voor de echte QR2-mapping en de benodigde historische preflight.

## Gegevenskeuzes

Een finalescan gebruikt de actieve onveranderlijke party-UUID, anders de account-UUID. Een party-ontvangst bindt de toen aanwezige registraties en volwassen accounts. Account-, registratie- en partijlidmaatschapshistorie voorkomen nieuwe rechten door partyverlating, samenvoegen of accountwissel. Zonder party behoudt een ander volwassen account zijn eigen accountrecht. Een duplicate geeft uitsluitend de eigen bestaande ontvangst terug.

Bij de eerste scan wordt een cohort bewaard: alle geaccepteerde volwassenen van huishoudens met een actief, aanwezig kind in die run. Eerder vertrokken kinderen leveren geen nieuwe cohortdeelname op. Dezelfde deadline geldt ook voor volwassenen zonder eigen scan. Herindeling verplaatst deze deadline niet. De server blokkeert nieuwe routeaanvang, scans, hervatten en gewone afronding vanuit een afgesloten eigen cohort; een andere bevoegde leider blijft volgens zijn bestaande rechten werken.

De eerste bevestiging maakt alleen aankomstbewijzen en zegels voor de expliciet bevestigde eigen account-/partijkinderen. De route en finale-reservering worden direct afgerond. Andere zelfstandige accounts kunnen later hun eigen bevestiging tegen dezelfde bewaarde finale-stop doen. Een aanwezig kind dat de beleving overslaat krijgt bij die bevestiging ook zijn zegel. Een gezamenlijke avondafsluiting alleen bewijst geen poortbezoek.

`first_finale_scan_at` en `evening_ends_at = first + 2 hours` worden samen onder een slot vastgelegd en zijn onveranderlijk. Het bestaande minuutproces `dispatch_all_due_routes()` verwerkt verlopen avonden. `processed_at` registreert de werkelijke verwerking; login/snapshots controleren de deadline meteen, ook vóór de worker. De mail-outbox gebruikt één blijvende sleutel per evenement/account; gateway-suppressies en bestaande accepted/delivered/unknown-afhandeling blijven van toepassing.

Oude finale-aankomstqueues blijven zakelijke ontvangsten herstellen via smalle adapters. Ze krijgen `accepted` en `completedStopId` terug, filteren oude groepskeuzes naar de eigen scope en maken geen showpoging aan. Alleen de nieuwe bewuste webactie kan na de transactie een actuele fysieke poging aanvragen.

## Uitvoeren

Gebruik uitsluitend een geïsoleerde lokale Supabase-stack met de repositorymigraties en `supabase/seed.sql`. De SQL-bestanden hieronder bevatten BEGIN/ROLLBACK en gebruiken geen echte e-mail of hardware. Via een bestaande lokale databasecontainer:

```sh
docker cp supabase/tests LOCAL_TEST_CONTAINER:/tmp/duinpad-tests
docker exec LOCAL_TEST_CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/duinpad-tests/121_duinpad_finale_evening.sql
docker exec LOCAL_TEST_CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/duinpad-tests/122_duinpad_checkpoints_show.sql
docker exec LOCAL_TEST_CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/duinpad-tests/123_duinpad_legacy_recovery.sql
docker exec LOCAL_TEST_CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/duinpad-tests/124_duinpad_frozen_cohort.sql
```

De concurrentieproef vereist een ongebruikte, apart aangemaakte lokale database met dezelfde migraties en synthetische seed. Zij commit alleen haar lokale proefgegevens en weigert gewone databasenamen:

```sh
DUINPAD_TEST_CONTAINER=supabase_db_LOCAL_TEST \
DUINPAD_TEST_DATABASE=duinpad_fresh_concurrency \
node scripts/acceptance/duinpad-finale-concurrency.mjs
```

De `*.log`-bestanden zijn het daadwerkelijke pgTAP-bewijs. De herbouw gebruikte een nieuwe offline PostgreSQL 17.6-container, de lokale Supabase-infrastructuurmetadata, de normale postgres-eigenaarsgrens, alle 133 appmigraties per bestand in een transactie en een verse synthetische seed. Cron-uitvoering stond uit. De concurrencyproef gebruikte een aparte lokale database met dezelfde app-/API-functies. Dit vervangt geen productie-backup/herstelproef of het bestaande releaseproces.

## Productiepreflight

`production-mapping-readonly.json` legt de werkelijke QR2-koppeling vast. QR1 is fysiek nog niet bewezen gekoppeld en moet via de nieuwe bevoegde beheeractie worden ingesteld. Er zijn geen tokens, hashes van credentials, secrets of e-mailadressen opgenomen.

Op het meetmoment waren er nul afgeronde canonieke finales. Voor een latere uitrol moet die alleen-lezen telling opnieuw gebeuren. Zodra deze groter dan nul is, is afzonderlijke historische beoordeling nodig; deze migratie verzint geen historische scanrechten of deadlines.
