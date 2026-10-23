# Migratie, staging en terugval

Status: uitrol in uitvoering. De gebruiker heeft productiepromotie expliciet opgedragen. Geldige projectautorisatie bestaat binnen de beschermde Actions-omgevingen; de vier expand-migraties staan op staging. Beide deployworkflows vereisen nu een backup-/hersteljob vóór enige migratie. Productie vereist de volledige succesvolle stagingworkflow, inclusief echte mailboxacceptatie, op precies dezelfde Git-SHA.

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

`scripts/deploy/redesign-backup.mjs` gebruikt in de beschermde omgeving een geëxporteerde, alleen-lezen repeatable-read-snapshot via de sessionpooler op 5432. De custom-format `pg_dump`-stroom wordt vóór opslag AES-256-GCM-versleuteld. De domeingescheiden HMAC-sleutel wordt afgeleid van de bestaande 256-bit serverkey in de secretstore; die key wordt niet naar deze ontwikkelmachine gekopieerd. Bewaar de oorspronkelijke key zolang de bijbehorende backups nodig zijn. De authenticatiecontext bindt omgeving, SHA, run en bestandsnaam. Bewaar geen plaintext-dump of ontsleutelsleutel bij het archief.

De job bewaart schema/data/ACL's, rolkenmerken en lidmaatschappen, Auth-/REST-/providerinstellingen en een apart versleuteld manifest. Elk Storage-object wordt als bytes opgehaald, versleuteld, geauthenticeerd en qua grootte/hash gecontroleerd; de metadata moet gedurende die kopie gelijk blijven. Provider-runtimegeheimen blijven in de bestaande secretstore. Dit is geen volledige VM- of fysieke providerbackup.

Het herstel gebruikt exact de geconstateerde Supabase/Postgres-image, een afzonderlijke container zonder netwerk en een uitgeschakelde cronlauncher. Voor het terugplaatsen van managed eventtrigger-eigenaars zijn uitsluitend in die wegwerpcontainer tijdelijk superuserrechten nodig; die worden na herstel teruggebracht naar de bronstand. Geen rol of instelling op het bronproject wordt daarvoor gewijzigd. Alle bestaande gecontroleerde rijen worden gehasht vergeleken, waarna dezelfde vier migraties op de kopie worden toegepast en bestaande kolommen opnieuw worden vergeleken. Het backfill-/legacyprintverslag blijft een preview; er wordt geen historische batch toegepast.

Alleen `.aes`-bestanden en een HMAC-getekend, niet-gevoelig `proof.json` worden dertig dagen als Actions-artifact bewaard. De deployjob valideert encryptie, omgeving/SHA en alle migratiehashes en kopieert deze bestanden naar `~/.local/share/duindorp-release-backups/<omgeving>/<run>-<attempt>/` van de dedicated runner, met directoryrechten 0700 en bestandsrechten 0600. Houd die privéretentie aan volgens het beheerbeleid; de automatische artifactretentie is geen onbeperkte bewaring.

De eerste echte stagingherstelproef vergeleek 169 tabellen en 12 opslagobjecten. Na de expand-stap waren dat 176 tabellen. Zie de afzonderlijke bewijslinks in `STATUS.md`; een geslaagde backupjob maakt een verder mislukte deployment niet alsnog geslaagd. Voor productie wordt dezelfde proef opnieuw op de werkelijke productiegegevens uitgevoerd.

## 3. Expand en droge migratie

| Migratie | Toevoeging / compatibiliteit |
| --- | --- |
| `20261023014941` | Historische aankomstfeiten, nullable `departure_reason`, geautoriseerde aankomst-/vertrekcommando's; bestaande routecontracten en `all_skipped` behouden; bestaande Poortenboek-trigger aangepast; bestaande codesnapshot-wrapper behouden |
| `20261023014942` | Private dagbevestigingen, volwassen-/kindertutorials, gelezen hoofdstukken, bedankjes en versleuteld printmateriaal; alleen veilige bestaande sessie-/boekuitbreiding; publieke eventtijden uit configuratie |
| `20261023020159` | Geautoriseerde Generale-functie; eigen fixture-event en echte domeincommando's in teruggedraaide subtransactie; geen blijvende oefenrijen |
| `20261023021247` | Service-only preview en begrensde, expliciet geselecteerde historische backfill; installatie voert geen backfill uit |

Nieuwe tabellen hebben RLS en geen rechtstreekse clientwrites; aankomstfeiten zijn uniek per stop/deelnemer, bedankjes per event/huishouden/poort. Nieuwe private gegevens beginnen leeg; een bestaande deelname of credential wordt niet naar demo-instellingen geconverteerd. Hash-only posters worden als legacy gemeld en blijven geldig. Herdownloadbaar materiaal ontstaat alleen bij een bevoegde, expliciete vernieuwing. Printencryptie gebruikt een apart afgeleide sleutel van de bestaande serverkey; behoud die sleutel en documenteer keyrotatie vóór gebruik.

Pas op de herstelde kopie de migraties in volgorde toe via het bestaande versiebeheer. Meet duur, lockwachttijd, queryplannen en invloed op gelijktijdige routeacties. Stel een korte lock-timeout en begrensde statement-timeout in de daadwerkelijke migratieverbinding in; verifieer dat de gekozen runner die instellingen gebruikt. Een ALTER TABLE neemt kort een exclusieve lock, ook met een nullable kolom. Nieuwe indexes/tablecreaties en functie-/triggervervanging zijn niet bewezen lockvrij. De migratiestap gebruikt maximaal vijf seconden lockwachttijd en vijf minuten per statement via `PGOPTIONS`; de eerste twee SQL-bestanden stellen zelf eveneens vijf seconden in. De eerste echte stagingkopie mat 85/79/64/64 ms. Dit meet uitvoering op die kopie, niet de maximale wachttijd bij gelijktijdig productiegebruik.

Voer eerst alleen `api.redesign_arrival_backfill(actor, event_slug)` als bevoegde service uit. Bewaar het kandidaten-/uitzonderingsrapport privé. Ontbrekende scan, systeemoverslag, onzekere aanwezigheid/vertrektijd of gewijzigde historische teamcontext worden niet gegokt. Huidig groepslidmaatschap alleen is geen bewijs. Selecteer na beoordeling maximaal 100 stop-IDs per batch, leg reden/reviewer vast en pas alleen die batch toe. Herhaling voegt geen dubbele aankomst/zegel toe. Vergelijk ook eventuele hoofdstuk-/journey-afleidingen apart. Verklaar iedere goedgekeurde nieuwe rij; iedere andere wijziging blokkeert.

De lokale test bewijst SQL-herhaalbaarheid en fixturecontracten. De eerste stagingmigratieduur en behoud van alle gecontroleerde bestaande rijen zijn gemeten. Het versleutelde previewrapport bevat historische kandidaten/uitzonderingen; het getekende bewijs bevat alleen aantallen. Er wordt geen automatische backfill uitgevoerd. Productie krijgt een eigen backup, herstelproef en datavergelijking.

## 4. Stagingacceptatie

Gebruik passende toegangsbescherming en geschoonde representatieve gegevens, met bestaande testontvangerafscherming. Houd productie-IDs/relaties in de private vergelijking consistent; verzend geen echte deelnemersberichten. Voer de bestaande CI, Supabase-migratie-/RLS-/Auth-/concurrencychecks en alle 66 regels uit `acceptance.csv` uit. Voeg echte gelijktijdige arrival/vertrek/rotatieproeven toe; opeenvolgende idempotentietests alleen bewijzen geen concurrerende telefoons.

Maak per hoofdomgeving en belangrijke dialoog passende desktop-/mobiele captures, los de fontafwijking op, controleer toetsenbord/focus/zoom/safe areas/reduced motion. Controleer oude QR's/sessies en beide poster-PDF's. Oefen offline/reload/commit-zonder-antwoord met echte services en gecontroleerde telefoon. Test zwart-witpapier, camera en iOS/Android/PWA apart.

Registreer pas daarna de exact gedeployde en geteste staging-SHA met datum, configuratievingerafdruk en bewijslinks. Leg de SHA pas vast nadat de volledige stagingworkflow is geslaagd. Een groen lokaal rapport mag dit veld niet invullen.

## 5. Productie en terugval

Het expliciete gebruikersakkoord voor productie is gegeven. Vóór promotie: controleer opnieuw de actuele basis, geldige backup/hersteltest, nulmeting en configuratie; voer de geteste expand-stappen uit, vergelijk data en stel pas de passende appversie beschikbaar. Geen resets, seeds, bulkvervanging of massale credentialrotatie. Houd veranderde toestanden na vrijgave traceerbaar.

App-rollback verwijdert de additieve tabellen/kolom niet. De oude app kan de uitgebreide snapshotvelden negeren, maar serverregels voor inclusieve aankomst blijven van kracht; oude UI die zonder scan wil afronden ontvangt `SCAN_REQUIRED`. Test deze combinatie vóór vrijgave. Bij onbruikbaarheid: houd de nieuwe, geteste serverregels en bied een gerichte compatibiliteitsfix of gecontroleerde operationele pauze; zet niet blind oude SQL-triggers terug die inclusieve zegels overslaan.

Bewaar nieuwe aankomstfeiten, vertrek, bedankjes, betalingen en ontvangstbewijzen. Herstel na ontvangst van echte transacties geen oude volledige backup als automatische rollback: reconcileer nieuw ontstane transacties vanuit append-only feiten/audit/receipts en pas gericht herstel toe. Een noodherstel vereist een afzonderlijk incidentplan met expliciet behoud van die mutaties en controle van externe betaal-/berichtreferenties. De uitvoerbare providerherstel- en rollbackproef staat nog open.

Promoveer via een fast-forward van de exact groene staging-SHA naar `production`. Een mergecommit of squash levert een andere SHA op en voldoet niet aan `require-staging-success.mjs`. Maak een reviewbare productie-PR en koppel die aan de taak. De productiejob verifieert het stagingbewijs opnieuw vóór de productiebackup, en nogmaals vóór de werkelijke uitrol. Na de CLI-migratie vergelijkt `redesign-postmigration.mjs` de bestaande domeinrijen en verifieert bestaande migratieregels en cronhistorie afzonderlijk. Alleen de vier bekende migratieversies en valide nieuwe/afrondende scheduleruitvoeringen zijn verklaarde metadatawijzigingen; elke andere afwijking blokkeert de appuitrol.
