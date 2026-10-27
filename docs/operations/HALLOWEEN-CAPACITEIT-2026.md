# Capaciteit en acceptatie voor 31 oktober 2026

Stand van onderzoek: 27 oktober 2026. Er is nog geen geslaagde hosted schaalacceptatie en geen vastgestelde piek van gelijktijdig geopende schermen. De 254 testidentiteiten zijn een testspecificatie, geen bezoekersprognose. De onderstaande clientverbeteringen verminderen aantoonbaar dubbel leeswerk; een hogere productiecapaciteit volgt daar pas uit na een nieuwe meting.

## Bewijs en versies

| Bron | Wat vaststaat | Praktische grens aan de conclusie |
| --- | --- | --- |
| [Draft PR 40](https://github.com/duindorpdoet/platform/pull/40), kandidaat `85d6d059…` | 200 gezinnen, 30 poortaccounts, 4 beheerders en 20 lezers: 254 afzonderlijke Auth-identiteiten. De schaalacceptatie is rood. | Dit is een andere code- en migrationlijn dan de huidige productie. |
| [Snapshotgolf op f9608bd](https://github.com/duindorpdoet/platform/blob/85d6d0591064489ee1df701643b41de87bfe6018/docs/evening/validation/hosted-load-after-aggregation.json) | 302/302 HTTP 200; roloperaties p95 **9.478 ms**, grens **8.000 ms**; 20 operaties boven die grens. Request-p95 is afzonderlijk 9.056 ms. Geen gemeten lockwacht; 7.281 oorspronkelijke rijen van 22 tabellen behouden. | HTTP 200 is geen acceptatie van responstijd. Dit bewijst geen CPU-verzadiging. Realtime: **0 pogingen**. |
| [Diagnose en configuratie op 24 oktober](https://github.com/duindorpdoet/platform/blob/85d6d0591064489ee1df701643b41de87bfe6018/docs/evening/validation/staging-capacity-diagnostics.json) | 32 afzonderlijke accounts, waaronder 30 poorteigenaren; meerdere HTTP-aborts rond twaalf seconden. Staging: `max_concurrent_users=200`, `connection_pool=2`, 100 events/s, 100 joins/s en 100 kanalen per client. Productieconfiguratie: HTTP 403 met stagingcredential. | De twaalf seconden zijn een diagnostische afbreekgrens, geen nieuwe acceptatiegrens. Identieke Prometheus-scrapes bewijzen geen CPU-belasting. De actuele Realtime-productiequota blijven onbevestigd. |
| [Actuele geaggregeerde controle](validation/realtime-capacity-20261027.json) | Beide `/api/health`-endpoints melden `86629f35df9ce2536106c6ac7957fb3a2b256be6`. Via de gekoppelde Supabase-app is voor beide databases `max_connections=60` bevestigd. | Een momentopname met weinig actieve verbindingen voorspelt geen avondpiek. Deze controle geeft geen Realtime-quota of PostgREST-poolgrootte. |
| [Oude lokale 200-clientproef](../implementation/load-acceptance-20260922.json) | Eén gedeelde bevoegde identiteit; gelijktijdige lezingen en identieke afrondingen. | Regressiebewijs voor idempotentie, geen bewijs voor 200 huishoudens of hosted capaciteit. |

De health-endpoints bevestigen dat PR 40 niet de huidige release is. De dertien migrations en performancecorrecties uit die PR mogen niet als aanwezig in `86629f35…` worden verondersteld. De staging- en productiebranch wijzen eveneens naar die laatste commit; voor de uitrolstatus is het health-antwoord de gebruikte bron.

## Wat de schermen daadwerkelijk belasten

De browser gebruikt één gedeelde Supabase-client per tab via `lib/supabase/client.ts`. Private Broadcast-berichten maken een snapshot ongeldig; de browser haalt daarna een geautoriseerde RPC-snapshot op. De onderzochte schermen gebruiken geen brede `postgres_changes`-abonnementen. Meer topics op dezelfde client betekenen extra joins, autorisatie en berichtontvangst, maar niet automatisch evenveel extra WebSockets. Verschillende telefoons of tabs van dezelfde gebruiker kunnen wel elk een verbinding openen.

| Scherm of bron | Lezingen in de onderzochte productiecode | Abonnementen en extra belasting | Wijziging in deze werkbranch |
| --- | --- | --- | --- |
| Route, `GroupExperience` | `group_snapshot` iedere 15 s en bij broadcasts; vóór vertrek voor de leider ook `group_roster`. De omhullende `WalkerSection` haalt gelijktijdig registratie, groep en voorkeuren iedere 15 s op, ook als uitsluitend de route zichtbaar is. | `group:<id>`; groepsgenoten ontvangen dezelfde invalidatie en doen ieder hun eigen geautoriseerde lezing. | De drie ongebruikte ouderlezingen vervallen op de routepagina. Routelezingen worden samengevoegd; het groepsabonnement gebruikt de bestaande gedeelde topicregistratie. |
| Meekijker, `ViewerSection` | `group_viewer_snapshot` iedere 15 s. | Deze component opent zelf geen route-WebSocket. De 20 testlezers in PR 40 gebruiken juist `live_support` en drie admin-RPC's; zij vertegenwoordigen dit scherm niet. | De gedeelde polling krijgt spreiding en begrenzing. |
| Poortkamer | `portal_room_snapshot` iedere 20 s, bij terugkeer en op beide topics. De snapshot bevat ook bezoek- en chatinformatie. | Twee private topics: poort en gemeenschap. Een gemeenschapsbericht kan alle geopende Poortkamers laten lezen. Open chat doet daarnaast `portal_chat_snapshot` iedere 15 s en bij broadcasts; historie en leesbevestigingen kosten extra aanvragen. | Beide topics delen één leeswachtrij voor de kamersnapshot. Bestaande topics blijven gedeeld met de chat. Polling loopt na voltooiing, met spreiding. Chatpayloads en moderatie worden niet samengevoegd of weggegooid. |
| Oud poortdashboard en prognose | `portal_dashboard` plus `portal_arrivals_snapshot`, ieder via eigen 15 s-refresh. | Prognose luistert naar `portal:<id>`. Dit is een ander scherm dan de Poortkamer. | Prognoselezingen worden samengevoegd. Het volledige oude dashboard is niet herschreven. |
| Adminoverzicht en livecockpit | Initieel `admin_dashboard`; een liveverversing doet tegelijk `admin_evening_cockpit` en `admin_portal_operations_snapshot`, iedere 20 s en bij broadcasts. Wisselen van sectie startte ook opnieuw dashboard en livelezingen. | Eventtopic geeft brede invalidatie. Aanvullende secties zoals Startregie en planbord hebben eigen RPC's, polling en soms hetzelfde topic. | Dashboard en livebron hebben elk één leeswachtrij. Automatische livelezingen alleen in de relevante bevoegde secties; geen volledige herlezing op iedere sectiewissel. De twee RPC's binnen één liveverversing blijven parallel. |
| Duurzaam planbord | `admin_live_planboard_snapshot` iedere 15 s en op eventbroadcasts. | Kan naast andere beheerschermen werken; eigen bronbudget blijft nodig. | Eigen leeswachtrij; maximaal één lopende snapshotlezing. |
| Hulpwidget en onboarding | Hulpwidget doet ook gesloten iedere 15 s `participant_messenger_context`; bij een gesprek een eigen messengertopic. De begeleidingslaag controleert circa iedere 30 s via de server. | Deze bronnen blijven boven op de routeload bestaan. Zij zijn niet opgenomen in de 302 initiële rol-RPC's van PR 40. | Vervolgopties; de bestaande bericht- en begeleidingscontracten blijven intact. |
| Kinderboek | Server-API met eigen kindsessie; op relevante secties polling iedere 12 s. Offline herstel kan iedere 1,5 s proberen. | Geen private Supabase-WebSocket vanuit het boek. Kinderen voegen wel HTTP- en databasewerk toe. | Bestaande privacy- en herstelwerking behouden; afzonderlijk meenemen in acceptatie. |

Bronnen: `components/participant/participant-shell.tsx`, `components/group/group-experience.tsx`, `components/portal/{poortkamer,poortkamer-chat,portal-dashboard,portal-forecast}.tsx`, `components/admin/{admin-console,live-planboard}.tsx`, `components/support/support-widget.tsx`, `components/redesign/participant-guidance.tsx` en `components/poortenboek/book.tsx`.

### Verbindingen, berichten en SQL zijn verschillende budgetten

De volledige SDK-proef van PR 40 vraagt minstens 254 afzonderlijke verbonden clients en **284 abonnementen**: 200 groepsabonnementen, 60 poort-/gemeenschapsabonnementen en 24 eventabonnementen. Zij past als specificatie niet binnen de laatst bevestigde staginggrens van 200 clients. Omdat de WebSocket-fase niet werd bereikt, is daarmee geen fout bij precies 200 verbindingen gemeten, zeker niet op productie.

`connection_pool=2` bij Realtime is de autorisatiepool voor private joins. Het is geen bewijs van twee verbindingen voor alle applicatie-RPC's. De HTTP/Data API gebruikt PostgREST; directe/poolerverbindingen, Realtime-autorisatie en `max_connections` moeten apart worden gemeten. Meer ruimte voor WebSockets maakt trage rol-RPC's niet vanzelf sneller. Zie [Realtime concepts](https://supabase.com/docs/guides/realtime/concepts), [limits](https://supabase.com/docs/guides/realtime/limits) en [database connection management](https://supabase.com/docs/guides/database/connection-management).

Tel voor een werkelijk scenario de **tegelijk geopende schermen per apparaat**, hun topics en hun RPC's. Eén deelnemer kan meerdere schermen gebruiken; één groepsleider kan ook de enige routeclient voor een groep zijn. Beide zijn te toetsen gebruiksscenario's. Er is geen bezoekersaantal uit de fixture af te leiden.

Voor de geselecteerde bronnen na deze wijziging is een eenvoudige bovengrens voor alleen periodieke aanvragen:

```text
R_periodiek ≲ (F + L)/15 + H/20 + 2A/20 + B/15 + V/15
              + K/12 + M/15 + U/30 + overige bronnen  [requests/s]
```

Hier zijn F routeschermen, L leiders die nog een roster nodig hebben, H Poortkamers, A livecockpits, B planborden, V meekijkers, K actieve kinderboeken, M hulpwidgets en U begeleidingslagen. Dit is een rekenmodel bij snelle antwoorden, geen benchmark. Aanvullende chats, starts, aankomsten, SSR, broadcasts en retries komen erbij. Met 200 geopende routes vervallen theoretisch 600 ongebruikte ouderaanvragen per 15 s; dit bewijst geen overeenkomstige hosted snelheidswinst. Werkelijke aantallen en schermmix zijn nog vast te stellen.

Berichtbelasting is `som(uitgezonden berichten × ontvangende abonnementen)`, plus clientberichten. Een eventbroadcast naar 24 beheerschermen telt dus niet als één bezorgd bericht. Ook het geobserveerde maximum voor events en joins per seconde moet tijdens een proef worden bewaakt; alleen de verbindingslimiet verhogen kan een tweede knelpunt blootleggen.

## Verbeteringen en benodigde infrastructuur

| Optie | Effect en voorwaarden | Bestaande infrastructuur of extra capaciteit |
| --- | --- | --- |
| Leeswerk bundelen en spreiden, zoals in deze branch | Broadcasts wachten 250–499 ms; maximaal één lopende verversing en één vervolg. Handmatig en na een commando wordt een nieuwe lezing afgewacht. Polling gebruikt het oude interval plus 0–20% spreiding **na** voltooiing; herstel na focus/online wordt 0–999 ms gespreid. Verborgen/offline schermen doen via deze hook geen periodieke lezingen. | Clientcode, geen infrastructuurwijziging. Vermindert overlap per bron, geen wereldwijd requestplafond. |
| Alleen benodigde abonnementen en broninvalidatie | Gebruik de gedeelde private topicregistratie ook voor resterende directe admin-/chatabonnementen. Laat gewijzigde resources alleen hun betrokken snapshots verversen. Haal bijvoorbeeld alleen een ongelezen teller op als de chat dicht is. | App- en eventueel RPC-aanpassing. Eerst testen dat teamintrekking, moderatie, meldingen en ongelezen aantallen blijven werken; geen privégegevens in publieke topics. Minder topics verlaagt niet vanzelf het aantal verbonden tabs. |
| Poortkamerlezingen zonder overbodige writes | De huidige `poortkamer_channels` voert bij lezen nog `ON CONFLICT DO UPDATE` en herhaalde archiefupdates uit. PR 40 heeft een geteste correctie voor uitsluitend echte overgangen en ontbrekende rijen. | Gerichte, additieve migration mogelijk binnen de huidige database. Eerst opnieuw valideren op de actuele schemalijn, inclusief gelijktijdige initialisatie en de bestaande lockproef; niet de hele oude release overnemen. |
| Gedeelde cockpitberekening en gerichte indexen | Behoud event-, bevoegdheids- en dataminimalisatiegrenzen. Meet per RPC en SQL-functie, met queryplannen/buffers en echte verschillende accounts. Bouw gemeenschappelijke bezettingsgegevens eenmaal op in plaats van per poort/groep. | SQL-optimalisatie kan zonder betaalde capaciteit. De oude aggregatie uit PR 40 moet worden aangepast aan nieuwe route-intenties en bevestigde ontvangsten. De honderden algemene FK-indexadviezen zijn geen bewijs dat al die indexen deze bottleneck oplossen. |
| Beperk leesconcurrentie en spreid vertrek/herstel | Spreid startmomenten volgens echte ontvangstcapaciteit. Bereid testsessies binnen de bestaande Auth-limiet voor; test de echte aanmeldpiek afzonderlijk. Laat minder belangrijke overzichten minder vaak lezen en geef aankomsten voorrang. | Operationele afspraken en appcode kunnen binnen de huidige omgeving. Een clientwachtrij regelt niet de som van alle apparaten; een centrale limiter/proxy of extra workers vereist een afzonderlijk ontwerp en configuratie. Mutaties niet laten vervallen in een leeswachtrij. |
| Meer Realtime-clients, events of joins | Nodig als de overeengekomen gelijktijdige WebSocketvraag inclusief andere projectgebruikers en reserve boven de bevestigde limieten uitkomt. De ongewijzigde proef met 254 clients overschrijdt de bevestigde 200. | Een aantoonbaar passende quota-/planwijziging, mogelijk betaald. Eerst productieconfiguratie door bevoegd read-only kanaal vastleggen; na wijziging opnieuw GET en een echte hosted proef. Een standaard prijstabel bewijst geen ingestelde productiequota. |
| Grotere Realtime-autorisatiepool | Kan private joins ontlasten als joinwachttijd de bottleneck blijkt. | Configuratiewijziging; alleen binnen gemeten databasebudget, eventueel grotere compute. Geen reden om de pool blind op 254 te zetten. |
| Meer databasecompute of een grotere PostgREST-pool | Overwegen bij gemeten CPU-, I/O-, geheugen- of poolwachttijd na queryverbetering. Verzamel twee verschillende tijdsamples en transactietijden; HTTP-duur is niet gelijk aan SQL-executietijd. | Betaalde compute en/of configuratie. Een grotere pool kan op kleine compute juist meer concurrentiedruk geven. Geen capaciteit aangeschaft of instelling gewijzigd in dit onderzoek. |

### Veilige terugval

De geselecteerde snapshotlezingen krijgen een afbreekgrens van acht seconden. Een mislukte lezing geeft geen nieuwe bevestigde voortgang. De route behoudt de bestaande gebruikers-/groepsgebonden cache; de Poortkamer markeert een mislukte bronlezing als offline en houdt haar bestaande verwijdering van privédata na vijf minuten. Admin- en prognosebronnen houden hun bestaande stand met een foutmelding. Polling blijft functioneren als een WebSocket niet aansluit. Een browser die nog online meldt te zijn, is geen bewijs dat de database bereikbaar is.

De wachtrij begrenst lopende aanvragen aan clientzijde. Een HTTP-abort bewijst niet dat de server de SQL-uitvoering heeft gestopt. Meet daarom ook late completions en werkelijke databaseconcurrentie; voeg een afgebroken mutatie nooit als nieuwe opdracht aan deze leeswachtrij toe.

De leeswachtrij wordt bij bronwissel en unmount weggegooid en deelt geen privéresultaten tussen gebruikers. De route negeert antwoorden uit een vorige scope of na afmelden. De bestaande versleutelde IndexedDB-aankomstqueue, idempotentiesleutel, versiecontrole, capaciteitstoets en servertransactie blijven leidend. Een herhaalde aankomst houdt dezelfde oorspronkelijke sleutel en scope; een onzekere uitkomst mag niet als een nieuwe onafhankelijke aankomst worden verstuurd. Een verouderde opdracht wordt niet door de client doorgeschoven en offline wordt geen ontvangstcapaciteit toegekend.

Een verdere noodmodus met minder WebSockets is een optie wanneer een passende verbindingenlimiet ontbreekt, maar verplaatst belasting naar polling. Die modus is pas bruikbaar na een gemengde HTTP-proef en zichtbare actualiteit per bron. Gebruik nooit gedeelde accounttokens, publieke routebroadcasts, het loslaten van reserveringslocks of langere acceptatiedeadlines om een proef groen te krijgen.

## Acceptatie voor de Halloweenavond

### 1. Leg een werkelijk belastingsprofiel vast

Maak uiterlijk vóór de definitieve repetitie een tabel van gelijktijdige groepsleider-/ouderroutes, extra meekijkers, kinderen met eigen boek, poortteamleden per telefoon, beheerders, chats en overige projectgebruikers. Bepaal piek bij vertrek, piek onderweg en gezamenlijke terugkeer na mobiel netwerkverlies. Leg de gekozen reserve expliciet vast; 20% kan een planningsvoorstel zijn, maar is geen bewezen veilige marge. Zolang deze aantallen ontbreken, rapporteer bereikbare testniveaus zonder ze aan bezoekersaantallen gelijk te stellen.

### 2. Accepteer exact de kandidaat en configuratie

Leg release-SHA, migrationlijst en hashes, werkelijke health-SHA's en actuele staging-/productieconfiguratie vast: compute, PostgREST-pool, databaseverbindingen, Realtime-gebruikers, events, joins en autorisatiepool. Noteer onbekende of geweigerde velden. Een bevoegd read-only configuratieoverzicht ontbreekt nog voor de productie-Realtime-quota. Een betaalde wijziging telt pas als aangevraagde en waargenomen waarden overeenkomen. Laat de CI, back-up/herstelproef en uitrol op dezelfde kandidaat horen.

PR 40 blijft als eigen releasekandidaat onder haar bestaande 254-gebruikersgate vallen. Deze branch versoepelt geen releasegate. Wanneer het werkelijke avondprofiel anders blijkt, documenteer een aanvullend operationeel acceptatiebesluit met die concrete schermmix; verklaar de bestaande rode 254-proef daarbij niet alsnog geslaagd.

### 3. Behoud de bestaande transactieregressies

Run de actuele applicatietests en pgTAP op een afzonderlijke lokale database. Gebruik `scripts/acceptance/load.mjs` voor haar beperkte één-identiteitsregressie, en de bestaande parallelle proeven voor aankomsten, laatste capaciteit, leiderschap, publiceren en actuele route-intenties. Hergebruik uit PR 40 de negatieve gevallen voor verloren commitantwoord, onafhankelijke retry, sluiten tijdens aankomst en actuele-versus-oude bronantwoorden, aangepast aan de uiteindelijke schemalijn. De fixture uit PR 40 is niet zonder meer een geldige fixture voor de latere groepsoperaties.

Vereist: hoogstens één fysieke aankomst en één bijbehorend zegel per kind/bezoek, exact één routeadvance, geen overboeking van fysieke of finaleontvangst, oorspronkelijke stop-/planbinding en voortgang behouden. Test zowel aankomst vóór sluiting als sluiting vóór aankomst; alleen een serverbevestigd toegelaten bezoek mag afronden.

### 4. Meet hosted fasen afzonderlijk

Gebruik de bestaande `evening-staging-load.mjs`, `evening-staging-http-profile.mjs` en hun accountbeveiliging/databehoud uit PR 40 als uitgangspunt voor de gekozen release. De scripts blijven beperkt tot expliciete lokale of stagingomgevingen. Begin met diagnose op kleine gemengde niveaus, bijvoorbeeld 25, 50 en 100 actieve identiteiten; dit zijn voorgestelde meetstappen. Test daarna het vastgelegde avondprofiel inclusief reserve en behoud de volledige 254-stressproef als afzonderlijk resultaat.

Meet niet alleen één gelijktijdige snapshotgolf:

1. Bevoegde onafhankelijke sessies voorbereiden, met gemeten Auth-limiet en tijdsafstand; daarnaast een afzonderlijke echte loginpiek met afgesproken aantallen en runner-IP's.
2. Gemengde HTTP-lezingen per werkelijk scherm. Rapporteer wachttijd aan clientzijde, netwerkduur, roloperatie, RPC, errors, aborts en p50/p95/p99/max. Stop mutatiefasen als de initiële grens faalt.
3. Een afzonderlijke, alleen-lezende private WebSocket-diagnose, zodat een voorafgaande HTTP-fout niet alle informatie over joins wegneemt. Rapporteer pogingen, succesvolle joins, gelijktijdige clients/topics, joinlatentie en expliciete foutcodes. Een overquota-negatieve proef is diagnose, geen releaseacceptatie.
4. Minimaal dertig minuten gemengd stabiel gebruik met echte browsers voor de belangrijkste schermen, naast de SDK-clients. Laat werkelijk broadcasts **én de daaropvolgende RPC-verversingen** lopen; open ook chats, meerdere teamtelefoons en kinderboeken. Tel alle geselecteerde bronnen.
5. Starts, aankomsten en finale onder dezelfde gemengde lezingen; herhaal onzekere aankomst met dezelfde sleutel vanuit onafhankelijke clients. Neem de werkelijke piek en een gecontroleerde herstelgolf mee. De clientwachtrij mag mutaties niet samenvoegen of automatisch opnieuw verzinnen.
6. Controleer accountbeveiliging en hashes van alle oorspronkelijke zakelijke rijen ook na een vroege afbreking. Breid de 22-tabellenlijst van de oude proef uit voor de nieuwe route-intenties, bevestigde ontvangsten en andere tabellen van de actuele release. Geen persoonsgegevens of tokens in de rapportage.

Handhaaf **p95 ≤ 8.000 ms** voor relevante rol-, route-, start- en aankomstoperaties, met uitsplitsing per rol/RPC zodat snelle groepslezingen trage beheerders niet maskeren. Een request met abort of onbekende commituitkomst telt niet als HTTP-succes; succesvolle retry mag de oorspronkelijke fout niet uit de statistiek verwijderen. De volledige proef vereist succesvolle verbindingen en broadcastontvangst op het gekozen profiel, geen ongecontroleerde reconnectlus, geen dataverlies en geen overboeking. Meet databaseverbindingen, actieve transacties, lockwacht, poolwachttijd, CPU/I/O/geheugen en Realtime-joins/events tijdens dezelfde golf.

### 5. Oefen terugval en herstel op de echte bedieningsschermen

Test afzonderlijk: WebSocket geblokkeerd met werkende HTTP, HTTP-uitval terwijl de browser online blijft, werkelijk verloren commitantwoord, tab naar achtergrond en terug, verlopen sessie, ingetrokken teamrol en een herstellende netwerkpiek. Meet tijd tot een frisse geautoriseerde stand. Bij alleen WebSocket-uitval geldt als voorgesteld refreshbudget het gemeten RPC-budget plus maximaal 18 s voor route/prognose en 24 s voor Poortkamer/cockpit; bij terugkeer naar een zichtbaar online tabblad komt hoogstens 999 ms spreiding bij. Leg een operationeel bruikbare eis vast voor urgente sluitingen; een normale pollingperiode is geen garantie op onmiddellijk bericht.

Voltooi ook het open praktijkbewijs uit PR 40: twee telefoons, poster/QR en korte code, werkelijk mobiel bereik, start-/wandel-/wacht-/finaleroute en leiderwissel. Deze lokale softwarecontrole vervangt dat bewijs niet. Verminder bij oplopende vertraging eerst niet-essentiële dashboardlezingen en spreid nieuwe vertrekken volgens de ontvangstplanning; laat onzekere aankomsten herstellen via hun bestaande queue. Bij een onbetrouwbare actuele stand geeft de organisatie gecontroleerde wachtinstructies.

## Uitgevoerde controles

De applicatiecontroles slagen: 534 tests, één overgeslagen bestaande integratietest, lint, typecheck, productiebuild en clientartifactscan. De nieuwe echte Chromium-proef ontvangt 21 private broadcasts en doet tijdens de meetgolf twee routelezingen, met maximaal één tegelijk en zonder ongebruikte registratie-/voorkeurlezingen. De proef is opgenomen in CI; de gewijzigde workflow is nog niet op GitHub uitgevoerd.

Ook de bestaande browserproef voor vervalste cookies, afgeschermde actuele route, offline cache en geautoriseerd herstel slaagt tegen een opnieuw opgebouwde, afzonderlijke lokale database. Daarbij blijft de volgende poort offline verborgen totdat de server de nieuwe stand bevestigt.

De complete lokale pgTAP-run is **rood**: 2.312 assertions in 94 bestanden, drie fouten in de bestaande tests `042_night_regie_map_and_group_composition.sql` en `059_redesign_contracts.sql`. De twee onboardingfouten uit 059 treden ook op met rechtstreeks uit de ongewijzigde baseline gelezen tests. Het groepsindelingsgeval uit 042 slaagt afzonderlijk; de fout in de volledige suite is nog onverklaard. Deze branch wijzigt geen migrations, seed of bestaande pgTAP-tests. Dit blijft open regressiebewijs voor de release.

Zie [het geaggregeerde meetbestand](validation/realtime-capacity-20261027.json) voor de controles en resterende grenzen. De nieuwe browsertest is na een lokale build apart uitvoerbaar met `pnpm exec playwright test --config playwright.realtime.config.ts`, met expliciete lokale Supabase-configuratie en `TOGETHER_TEST_DB_CONTAINER`. Zij is geen hosted belastingacceptatie.

Er is geen deployment, productiemigration, betaalde upgrade, quota-aanpassing, credentialrotatie of hosted belastingproef uitgevoerd. De bestaande lokale checkout en haar losse bestanden zijn ongemoeid gelaten; het werk staat in branch `codex/realtime-capacity-20261027`.
