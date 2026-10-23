# Validatie en visuele vergelijking

Bron: overdrachtcommit `e2bff0bd8575595257a39d65284d8dba43ad9f94`, 464 gecontroleerde checksums, geopende HTML-galerij en alle oorspronkelijke beelden. De drie referentiesuites slagen met 36 controles. De productieserver gebruikt de bestaande Next-/Supabase-applicatie.

| Onderdeel | Bewijs in deze repository |
| --- | --- |
| OPS-01, tijdpublicatie en revisies | `065_start_ops_server_boundaries.sql`, `start-ops.spec.ts`, twee echte Auth-clients in `start-ops-concurrency.mjs` |
| OPS-02, echte wandelkoppeling en locatiecorrecties | `065`, `067_live_new_house_and_time_guards.sql`; geen automatisch goedgekeurde demo-node |
| OPS-04, grootste gezinsafwijking | bestaande plannerunitcontroles en de afzonderlijke gezinsdetails in de echte beheerinterface |
| OPS-05, hervatten en actuele huisstatus | private Realtime plus zichtbaar/online-interval en focus/pageshow/online; bestaande Auth-/offline- en Poortkamerregressies |
| OPS-06, Amsterdam en foutinvoer | `lib/time/amsterdam.test.ts`, `067`, mobiele echte formulierproef in `start-ops.spec.ts` |
| OPS-07, gekoppeld starthuis | `069_linked_start_house.sql`: echte publicatie, vertrek, scan, buitenblijven, afwezige kinderen en uitgeschakelde telinstelling |
| OPS-08, behoud en capaciteit | `065`, `068_large_group_full_journey.sql`, plannerunitcontroles en echte parallelle plan-/publicatieproeven |
| SEC-01 | `066_push_server_security.sql`, `push-security.test.ts`, HTTP-test in `start-ops.spec.ts`; synthetische provideradressen worden niet verzonden |
| Groepsmaximum | `064_event_group_size_policy.sql`, echte Auth-proef `group-size-policy.mjs`, browserinstellingen 30/45/impact; volledige 45-kindketen in `068` en `ops-large-group.spec.ts` |
| Noodzakelijke mededelingen | `063_essential_event_notices.sql`: uitgeschakelde gewone updates veranderen de noodzakelijke doelgroep niet; geen consent-backfill |

De 45-kindketen gebruikt de echte registratie-, betalings-, planning-, bevestigings-, publicatie-, vertrek- en aankomstcommando's. De HTTPS-browsertest hergebruikt deze gecontroleerde synthetische fixture uitsluitend in een lokaal gereset project. De echte mobiele deelnemerslijst bevat 45 kinderen; iedere persoonlijke boekprojectie heeft één eigen zegel. De echte browser downloadt de persoonlijke PDF, waarin geen adres of sessietoken staat.

## Beelden bij dezelfde viewport

De bestanden in `screenshots/` gebruiken uitsluitend synthetische gegevens. `start-1348.png` en `route-1348.png` zijn 1348 × 926. `start-390.png`, `start-360.png`, `route-390.png` en `route-360.png` tonen de echte applicatie zonder telefoonframe. `publication-desktop.png` toont het afzonderlijke publicatievenster. `group-policy-impact-390.png` toont de bewaakte verlaging. De latere mobiele fout-/pushbeelden en grote-groepbeelden worden door de bijbehorende browsertests geproduceerd.

Bewuste verschillen met het prototype:

- Bestaande echte organisatienavigatie en waarschuwingen blijven aanwezig; geen prototypebalk of klokbediening.
- Werkelijke inschrijvingen, betaalstatus, routebeschikbaarheid en rechten bepalen de toestand. Daardoor verschillen aantallen, namen en routevorm van de fictieve bronbeelden.
- De bestaande server kent extra kaders en een onafhankelijke finaleconfiguratie. Een ontbrekende configuratie geeft een concrete fout in het publicatievenster.
- Veilige wandelrouting levert afstanden waar het netwerk die kent. Schematische lijnen worden expliciet als volgorde, met waarschuwingen en voorlopige schatting, beschreven.
- Beide bestaande punt-/huisdialogen staan boven de vaste mobiele navigatie. De browsertest vond dat de oude laagvolgorde de opslagknop kon bedekken; de correctie houdt knoppen bereikbaar. Escape, focusbegrenzing en terugkeer naar de opener worden werkelijk bediend.
- De bron gebruikt systeemfonts; op deze Linux-runner kan de fontfallback afwijken van de broncomputer. Dit is geen bewijs van pixelidentieke tekstmetrics op ieder apparaat.

## Praktijkgrens

Dit bewijs omvat server-, database-, browser- en PDF-paden. Een daadwerkelijke straatcontrole, fysieke QR-scan/printproef en pushbezorging op afzonderlijke echte apparaten zijn geen onderdeel van de uitgevoerde lokale of CI-proeven. De productieapp toont geen fictieve verklaring dat zulke controles al zijn uitgevoerd.
