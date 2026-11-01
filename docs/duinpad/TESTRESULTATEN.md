# Testbewijs en grenzen

Geteste appcode: **`b0e5e7e6127f930d2d0c645d4a299595dab0993e`**, branch `codex/duinpad-actors-finale-20261031`, basis `db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`. De aparte bridge-identiteit is patch-SHA256 **`332d2cbc26f0d8257d7e6cf61d5cddb44f5a35a8be73f02cc1aad08dd8a0a26b`** tegen de onveranderde 2.0.0-baseline. Latere documentatiecommits veranderen deze geteste bron niet. `pnpm verify` draaide op `28415699ca5b8addad02fbddb4819461b22416d2`; de componentbrowser op `bfd44ba7d241f8035676a07812573a4ebb8cf5db`. Alle app-, component- en testbronnen voor die controles zijn identiek aan de eindbron; de latere bronwijzigingen betreffen uitsluitend SQL en het afzonderlijke bridgepakket. [Controlecontext](evidence/verification-context.json). De volledige SQL-suite is opnieuw op de exacte eindbron uitgevoerd.

| Uitgevoerde controle | Omgeving | Werkelijke uitslag en bewijs |
|---|---|---|
| `pnpm verify` | Node 24.18.0, pnpm 11.25.0, Next 16.3.5; bestaande app | Lint, TypeScript, **1.194 tests geslaagd**, één bestaande optionele integratietest overgeslagen; productiebuild geslaagd; 1.465 clientbestanden gecontroleerd. [Volledige uitvoer](evidence/pnpm-verify.log). |
| Alle 133 migraties vanaf een nieuwe lege applicatieschema-basis + synthetische seed | Nieuwe offline Supabase Postgres 17.6-testcontainer; netwerk uit; actieve cronjobs uit | Geslaagd. De bestaande lokale/productiedatabase is niet gereset. [Definitieve migratie-uitvoer](database/full-suite/all-133-migrations.log), [exacte checksums en volledige SQL-asserties](database/full-suite/summary.json). |
| Alle 125 pgTAP-bestanden | Dezelfde opnieuw opgebouwde testdatabase | **3.448 controles geslaagd**: alle bestaande repositorycontracten, gewone routes, deelnemeromgeving, ouder/Poortenboek, Poortkamer, aankomst/bedankjes, accountkeuze, printcredentials, acteurs, finale, legacy recovery, herindeling, gedeelde receipts en expliciete weigering van accounts zonder route. [Per bestand log en modelkeuzes](database/README.md). |
| Parallelle scans en deadlineworkers | Aparte lokale synthetische racedatabase; functiedefinities gelijk aan migratiebasis | Drie gelijktijdige scans: twee unieke units, één vaste deadline, drie aankomsten en drie zegels. Twee workers: vier unieke volwassen-accountmails. Een echte 1,5 seconde lock-wacht over de deadline wordt ook voor een later geaccepteerde volwassene buiten het mailcohort afgewezen. [Resultaat](database/full-suite/concurrency.json). |
| Componentbrowser met echte Reacthandlers | Chromium, 320/390 px, synthetische HTTP-responses en auth-state callbacks | **54/54 controles geslaagd**: leesbaarheid, tikvlakken, toetsenbord, reduced motion, twee QR-kaarten, tweestapsfinale, skipkeuze, serverafsluiting, unknown zonder POST-retry, actuele rechten, stale status, gedeeld finaleherstel zonder oorspronkelijke acteur en accountwissel tijdens vertraagde receipts/retries/403. [Gedetailleerd rapport](evidence/component-browser.json), [acht screenshots](screenshots/). |
| Bridge/relay-simulatie | Python 3.12.3; geïsoleerde testdependencies; nep-QLC/audio | **112/112 controles geslaagd**: 72 bestaande en 40 nieuwe. HMAC/scope/revision, zonegrenzen, gedeeld fysiek slot, beide start-ACKs, partial failure, herstart, offline, readonly receipts, herstel na intrekking van de oorspronkelijke acteur, behoud van unknown-selectie bij herstart/Nieuwe ronde en lokale regieafhandeling. Compileall, JavaScriptcontrole en aparte patchtoepassing geslaagd. [Volledig rapport](bridge/TESTRAPPORT-ACTOR-V1.json), [uitvoer](bridge/unittest-simulation.log). |

De geteste bron heeft geen packageupgrade. Een eerste build met een node_modules-symlink werd door Turbopack geweigerd. De definitieve build gebruikte dezelfde geïnstalleerde dependencies in de geïsoleerde werkcheckout en slaagde met het normale buildcommando. Eerdere regressieproeven op een gebruikte lokale fixturebasis zijn vervangen door de volledig nieuwe offline migratiebasis hierboven. Eerdere tussenresultaten zijn geen vrijgavebewijs.

## Relatie met het aangeleverde acceptatieplan

Het volledige uitvoerbare oorspronkelijke plan staat in [ACCEPTATIEPLAN.md](ACCEPTATIEPLAN.md). Dit overzicht maakt onderscheid tussen bewezen softwaregedrag en nog niet uitgevoerde liveproeven.

| Plan-ID's | Softwarebewijs op bovenstaande commit/patch | Resterende beperking |
|---|---|---|
| A01–A06 | Scoped API-tests, 121/122/123, browser: servergroep, vrijgegeven echte finale, twee stappen, overslaan met zegel | Geen fysieke wandeling met productieaccounts. |
| B01–B07 | 121/124, concurrency, browser: +2 uur, exact grensmoment, dubbele/latere scans, cohort, browser gesloten/terugkeer, relayblokkade | Geen twee uur durende liveavond nagebootst als echte uitvoering; tijdgrenzen komen uit synthetische DB-fixtures en echte lock-wacht. |
| C01–C09 | Bridge/relay 112, show/API-tests, 122: QR1 alleen aanmelden, lokale voorwaarden, beide ACKs, gedeeld slot, blocked/offline/unknown/deadlines | QLC/audio zijn gesimuleerd. Hoorbaarheid, zichtbaarheid, fysieke vrijgave en locatieklokken zijn niet geverifieerd. |
| D01–D10 | Actor-pgTAP60, protocol/API/claim/gatewaytests, browser54, bridge: uitnodiging, actuele rechten, scopes, intrekking, unknown | Werkelijke OTP-ontvangst, Google-login/cancel en mobiele productieverbinding niet getest. Actieve grants hebben de expliciet gedocumenteerde maximale vijfseconden-grens bij onbereikbare revocatiepush. |
| E01–E06 | Bestaande060 + nieuwe121, parallelle workers, premiumgateway/hooktests en browser: eigen bereikte poorten, upsert, dedupe, mailstatus | Alleen synthetische outbox/mocks; geen echte mail verstuurd of bezorgwebhook ontvangen. |
| F01–F07 | Volledige verify, alle 125 SQL-suites, browser54, bridge112, behoud van releasechecks en secretscan | Lokale schemaherbouw is geen productierijen-/backuprestorebewijs. De bestaande staging/productie-releasegates, live advisors en de uitgebreide CI-uitvoering blijven afzonderlijk. |
| G01–G06 | 121–124, concurrency, bridge + auth-races: QR1-hergebruik, readonly status, interne zones, partyhistorie, HMAC, herstart/reset | Geen live showcomputerherstart of fysieke reset uitgevoerd. |
| H01–H02 | 122 en browser54; bestaande vector-A4-PDF-tests: mapping, twee credentials/stadia, aparte kaarten, download/print, geen code-rotatie bij ophalen | QR1-locatie nog onbekend; de nieuwe productie-downloadroutes zijn nog niet uitgerold en er zijn geen echte posters op locatie gescand. |

## Uitvoerbare herhaling

```sh
pnpm verify
node scripts/acceptance/duinpad-browser.mjs
```

Voor de SQL-suites: bouw alleen een **nieuwe geïsoleerde synthetische database** met de bestaande migraties en seed. Voer vervolgens alle bestanden uit `database/full-suite/summary.json` met `psql -v ON_ERROR_STOP=1` uit. De tests zelf gebruiken transacties/rollback. Reset geen bestaande omgeving. Gebruik voor races de expliciet lokale configuratie van `scripts/acceptance/duinpad-finale-concurrency.mjs`; het script controleert de synthetische databasegrens en maakt geen show- of mailproviderverbinding.

De bridge heeft een apart uitvoerbaar test- en toepasplan in [bridge/README.md](bridge/README.md). Het oorspronkelijke bronpakket blijft de basis voor audio/QLC/media.

`supabase db advisors --help` is geverifieerd. De CLI kon niet in de volledig offline Alpine-testcontainer starten doordat diens runtime-loader ontbreekt; er wordt geen geslaagd advisorresultaat geclaimd. De expliciete databasebeveiligingsasserties hierboven zijn wel uitgevoerd. De bestaande releaseworkflow voert haar advisorcontrole ongewijzigd uit bij een geautoriseerde release.

## Niet uitgevoerd

Geen productie-uitrol/migratie/herstart, echte uitnodiging of bedankmail, live Google/OTP-proef, QLC-/audio-uitvoer, Art-Net of rook. Een software-ACK is geen fysiek showbewijs. De echte QR2-identiteit en historische nulmeting zijn uitsluitend gelezen; [productiemappingbewijs](database/production-mapping-readonly.json) bevat geen credentials of persoonsgegevens.

Op het gemeten moment waren er nul reeds afgeronde canonical finales met aankomstbewijs. Herhaal die alleen-lezen controle bij release; veronderstel niet dat deze momentopname de hele avond geldig blijft. Bij nieuwe historische finalegevallen moet de release eerst hun scan-/deadlinecompatibiliteit beoordelen, zonder reset of verzonnen bewijs.
