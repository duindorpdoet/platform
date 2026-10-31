# Duinpad actoradapter v1 en ontvangstherstel

Deze wijzigingsset hoort bij de bestaande Halloween-app en Showpakket 2.0.0. Er is geen nieuwe productieapp. De uitgaande WSS-verbinding `/engine` blijft de enige internetverbinding naar de showcomputer. QLC+, audio, Art-Net, rook en de showtijdlijn blijven lokaal. De normale voorbereiding, cue-timing, audiokanalen, finaleprioriteit en rookstandaard zijn niet gewijzigd.

De extra SQLite-tabellen worden met `CREATE TABLE IF NOT EXISTS` toegevoegd bij openen van de bestaande database: `actor_access`, `remote_attempts`, `finale_slots`, `finale_resolutions`. Een bestaande `remote_attempts` krijgt additief een nullable `operation`-kolom; elke nieuwe poging bewaart de gevalideerde actie daarin onveranderlijk vóór uitvoering. Bestaande events, controllerstaat en logboek blijven staan. Maak voor een bevoegde uitrol een kopie van de bestaande SQLite-database inclusief WAL/SHM volgens de lokale beheerprocedure; wis geen groepen, events of productiegegevens voor installatie.

## Configuratie en compatibiliteit

Op app-backend, relay en showcomputer zijn dezelfde **afzonderlijke** `DUINPAD_ACTOR_AUTH_SECRET` (minimaal 32 tekens) en `DUINPAD_EVENT_SCOPE_ID` (het werkelijke Halloween-event-ID) nodig. De bestaande `DUINPAD_RELAY_SECRET` wordt niet geroteerd. Het actorsecret mag niet gelijk zijn aan het relaysecret; de relay weigert ook gelijkheid met de oude bezoekergeheimen. De nieuwe `.env.example` bevat lege actorwaarden. Dit document levert geen geheimwaarden, domein of evenement-ID.

App-backend gebruikt `DUINPAD_SHOW_API_BASE_URL` (bestaande echte HTTPS-relayorigin) en `DUINPAD_SHOW_API_TOKEN` (bestaande relaysecret). De showcomputer gebruikt de bestaande `DUINPAD_RELAY_URL` (echte WSS `/engine`-URL) en `DUINPAD_RELAY_SECRET`. Geen sleutel of ondertekende grant gaat naar de browser, QR-poster, `NEXT_PUBLIC_`, URL-query, foutmelding of auditlog.

De nieuwe showcomputer meldt na verbinden `type:capabilities`, `versions:['duinpad.actor.v1']`, `event_scope_id`, `observed_at`, `actor_status_max_age:5`, `zone_stops:[2,3,4]`, `finale_receipts:1`. Zonder passende onderhandelde mogelijkheden zijn alle nieuwe actor/status/receiptpaden 503 en wordt niets bewaard voor later. Het gedeelde finaleherstelpad vereist expliciet `finale_receipts:1`. De bestaande QR1/QR2-wirevorm blijft terugwaarts compatibel. Een oude relay of oude bridge ondersteunt de nieuwe acteurbediening niet.

Controleer vóór livegebruik kloksynchronisatie op VPS, relay en showcomputer. Actorgrants zijn maximaal vijf seconden geldig; toekomstige en verstreken grants worden geweigerd. Een klokafwijking blokkeert zo veilig. Status wordt live opgevraagd en bij meer dan vijf seconden ouderdom afgewezen. Een geldige QR-poster en een verbonden showcomputer zijn afzonderlijke feiten.

## Gesloten protocol

Alle interne HTTP-paden vereisen `Authorization: Bearer <bestaand relaysecret>`. De telefoon spreekt uitsluitend de eigen geauthenticeerde app-API. Request bodies hebben maximaal 4096 bytes. Eén relayworker, één engineverbinding, maximaal 64 gelijktijdig wachtende relayrequests en maximaal acht actieve softwareworkers op de bridge; er is geen duurzame of offline showqueue en geen reconnect-replay.

Envelope: `{version:'duinpad.actor-envelope.v1',payload,signature}`. `payload` is base64url zonder padding van de **exact verzonden UTF-8 JSON-bytes**. `signature` is base64url zonder padding van HMAC-SHA256 over de ASCII `payload`-string. Het volledige command is getekend. Dubbele JSON-keys, niet-canonieke base64url, extra velden, niet-eindige getallen en onbekende acties worden geweigerd; handtekeningvergelijking is constant-time.

Commandpayload (exact conform het aangeleverde schema):

```json
{"version":"duinpad.actor.v1","command_id":"<unieke poging>","event_scope_id":"<echt event-ID>","actor_subject":"<geverifieerd account-ID>","permissions_revision":1,"action":"zone1.trigger","group_id":null,"args":{},"issued_at":0,"expires_at":8,"scope":{"permission":"zone1.trigger","internal_zones":[2]}}
```

De tijden in het voorbeeld zijn alleen veldillustratie en zijn nooit uitvoerbaar. Uitgifte gebruikt actuele Unixseconden, `expires_at > issued_at`, `expires_at <= issued_at+8`; uitvoering controleert ook de lokale twintigsecondenregel. `heks.go` en `finale.go` vereisen de actuele lokaal geselecteerde groep. Alle andere acties vereisen `group_id:null`. De backend haalt de groep uit verse lokale status; een browser kiest geen groep. Ready heeft uitsluitend `{ready:boolean}`. Alle andere `args` zijn `{}`.

Een verse accessgrant gebruikt dezelfde envelope met payload `{version:'duinpad.actor-access.v1',event_scope_id,actor_subject,permissions_revision,permissions:[...],active:boolean,issued_at,expires_at}`. `expires_at <= issued_at+5`. Ingetrokken toegang heeft `active:false,permissions:[]`. Rechtenwijzigingen/intrekking verhogen de revision. Lagere revisions en inhoudelijk gewijzigde rechten bij dezelfde revision worden geweigerd en de hoogste revision blijft bewaard na herstart.

| HTTP-pad | Invoer / betekenis |
|---|---|
| `POST /api/integration/actor-access` | Accessgrant-envelope als JSON-body; push rechtenwijziging/intrekking; ACK na duurzame lokale update. Geen cue. |
| `GET /api/integration/actor-status` | Header `X-Duinpad-Actor-Grant` = base64url UTF-8 compact JSON **envelope** van de verse accessgrant. Retourneert alleen de eigen controls. |
| `POST /api/integration/actor-command` | Command-envelope body plus dezelfde grantheader. Eerst live grant-sync, daarna hoogstens één directe uitvoering. |
| `GET /api/integration/receipts/<id>?kind=actor&payload_hash=<sha256>[&group_id=<id>]` | Verse eigen grantheader. Hash = SHA256 van exacte gedecodeerde command-JSON-bytes. Leest uitsluitend. Laat `group_id` weg voor null. |
| `GET /api/integration/receipts/<id>?kind=qr&group_id=<id>&payload_hash=<sha256>` | Geen actorgrant. Vertrouwde backend bewijst in de app de eigen groepsautorisatie. Hash volgens onderstaande QR-normalisatie. |
| `GET /api/integration/finale-receipts/<id>?group_id=<id>&payload_hash=<sha256>&event_scope_id=<event>` | Uitsluitend backend-Bearer; de app verifieert eerst de eigen deelnemer-/evenementbeheerautorisatie. Exact gebonden bewijs van alleen QR2 of actor `finale.go`, ook als de oorspronkelijke acteur is ingetrokken. Geen actorgrant of uitvoeringsrecht. |
| `GET /api/integration/group-status?group_id=<id>` | Beperkte status van uitsluitend die groep; backend autoriseert de browser. Geen volledige groepenlijst. |

De relay stuurt uitsluitend vaste packetkinds `actor.access`, `actor.status`, `actor.command`, `receipt`, `finale.receipt`, `group.status` en het bestaande `qr` over WSS. Er is geen generieke regieproxy of willekeurige interne actie-/zoneparameter.

QR-hash gebruikt exact compact JSON met vaste keyvolgorde `{stage,group_id,event_id,issued_at,label}`; ontbrekend label wordt `''`. De app gebruikt gehele Unixseconden. Een receiptquery verandert nooit `issued_at`, maakt geen event en roept geen start aan. Een oude POST opnieuw sturen is nadrukkelijk geen statusquery.

Statusbody: `{version:'duinpad.actor-status.v1',compatible:true,connected,observed_at,permissions_revision,controls:[{action,enabled,blocked_reason,group_id,effect:{active,remaining}}]}`. Uitsluitend toegewezen acties; geen deelnemers, andere actorrechten, labels, `next_intro`, `next_finale`, hardwareconfiguratie of geheimen. De backend controleert revision, ouderdom en eigen permissions nogmaals.

Command-ACK: `{ok,message?,duplicate?,unknown?,error?,outcome,command_id,meaning?,confirmation?}`. `meaning` is `scene_started`, `finale_started`, `ready_updated`, `zone_stopped` of `all_stopped`. Alleen finale-ACK bevat `confirmation:{qlc_started:true,audio_started:true}` en pas nadat beide lokale motoren hebben bevestigd. Dit bewijst geen fysieke zicht-/hoorbaarheid of showvoltooiing. `ok:false` met `outcome:'blocked'` is een expliciete weigering; timeout/verbroken verbinding is `unknown`. Een niet verstuurd command geeft 503/`not_dispatched`. Geen automatische retry.

Receiptwrapper: `{found,command_id,group_id,payload_hash,result,group?}`. Alleen bij exact ID, hash, soort, groep, event en eigen actor is `found:true` mogelijk. Een miss blijft `found:false,result:{ok:false,unknown:true,outcome:'unknown'}`; ontbrekend bewijs is geen bewijs van niet uitgevoerd. De receipt-handler schrijft geen capability, receipt of controllerstaat. Hij kan een eerdere unknown teruglezen als gestart als het duurzame **zelfde poging-ID** beide start-ACKs bewijst, of als expliciet niet uitgevoerd na de lokale regiehandeling hieronder.

Het aparte gedeelde finaleherstelpad voegt `event_scope_id` toe aan deze wrapper en is begrensd op het fysieke finaleslot. Het vergelijkt exact het oorspronkelijke poging-ID, de opgeslagen payloadhash, groep en evenement en eist de onveranderlijke operatie `qr2` (bron qr) of `finale.go` (bron actor). Een actorclaim of huidige acteursrechten zijn daarvoor niet nodig: de vertrouwde backend autoriseert de deelnemer/evenementbeheerder tegen diens eigen groepscontext en opgeslagen poging. Het antwoord bevat geen oorspronkelijke acteuridentiteit, permissions, claim, lokale auditreden of volledige regiestatus. Dit leest alleen bewijs en geeft nooit een commandobevoegdheid.

Bij oudere rijen zonder `operation` wordt uitsluitend read-only de bij **hetzelfde poging-ID** opgeslagen lokale eventpayload gecontroleerd op de exacte gebonden finaleactie. Zonder dat bewijs wordt niet gegokt dat een ongetypeerde pending rij een finale was. Een ontbrekende rij, lege groepenlijst, intrekking, huidige ready-status of momenteel stilstaand effect is nooit niet-uitvoeringbewijs. Na intrekking van acteur A kan een bevoegde andere deelnemer/beheerder zo het gedeelde slot pas herstellen als dezelfde duurzame ACK of expliciete lokale regiebeslissing dat rechtvaardigt.

## Rechten en races

| Internetpermission | Lokale rol / actie |
|---|---|
| `heks.ready`, `heks.go` | heks / interne 1 / ready of gebonden GO |
| `zone1.trigger`, `zone1.stop` | pad1 / interne 2 / GO of alleen zone 2 stoppen |
| `zone2.trigger`, `zone2.stop` | pad2 / interne 3 / GO of alleen zone 3 stoppen |
| `zone3.trigger`, `zone3.stop` | pad3 / interne 4 / GO of alleen zone 4 stoppen |
| `finale.ready`, `finale.go` | finale / interne 5 / ready of dezelfde gebonden QR2-finalestart |
| `stop-all` | uitsluitend expliciete globale emergency-scope; geen presetrecht |

De oude lokale rollen mogen meer dan de internetadapter. De adapter erft nooit hun algemene emergency-knop. Zone 1/5 is nooit een internet-zonestop. Tijdens een finale weigert de controller ook beperkte padstops als de finale het pad bestuurt.

Onder de controllerlock worden vlak vóór uitvoering handtekening, event, groep, deadline, actieve capability, hoogste revision en verse grant opnieuw gecontroleerd. De WSS-ontvanglus verwerkt revocaties terwijl een startworker op die lock wacht. Een ontvangen nieuwe revision blokkeert zo oude nog niet uitgevoerde opdrachten. Een lopende cue stopt uitsluitend via een afzonderlijk toegewezen stoprecht of lokale regie.

De app controleert actuele DB-rechten vlak vóór iedere dispatch en pusht intrekking/revisions naar de bridge. Als die push niet bevestigd wordt, moet de UI dat melden. Een onbereikbare verbinding kan geen onmiddellijke remote intrekking bevestigen: bestaande grants verlopen uiterlijk na vijf seconden. Claim daarom geen onmiddellijke synchronisatie bij een mislukte push; er wordt niets automatisch opnieuw gestuurd.

## Eén finale en lokaal herstel

QR2, internet-`finale.go` en lokale handmatige Finale GO delen dezelfde controllerlock en duurzame `finale_slots`-rij. Reservering gebeurt direct vóór de lokale motorstart. Alleen na QLC- én audio-ACK wordt de rij `started` en Heks GO voor de volgende groep vrijgegeven. Geen automatische Heks GO. Een fout vóór beide ACKs houdt het slot unknown en de volgende heks geblokkeerd. Een reset van de lokale groepenlijst wist dit slot niet.

Bij een herstart worden geen cues hervat; actieve groepen worden interrupted en regieherstel blijft nodig. Een receipt van een historische bevestigde start kan tegelijk `group.recovery_required:true` melden. Toon dit als herstelcontrole; het historische ACK-bewijs geeft geen nieuwe startmogelijkheid.

Een bestaande onzekere finalegroep blijft na herstart en **Nieuwe ronde** de lokale finaleselectie voor herstel. Bij Nieuwe ronde met één aantoonbare bestaande onzekere groep blijft die exacte binding bewaard; de interrupted-groep is uitsluitend een hersteldoel. Het duurzame unknown-slot blijft GO weigeren en opnieuw starten van het programma geeft geen volgende-Heks-vrijgave zolang een unknown bestaat. Een lokale reeds bevestigde start heeft daarentegen terecht geen awaiting-selectie meer: gebruik voor historisch gedeeld ontvangstherstel de exacte geautoriseerde app-DB-poging en routegroep, zonder een huidige lokale selectie als vervangend bewijs te behandelen.

Bij unknown:

1. Vraag uitsluitend de eigen receipt/status op; herhaal geen uitvoerings-POST en verzin geen nieuwe poging-ID.
2. Controleer ter plaatse QLC, audio, controllerlog en de groep. Een ontbrekende receipt of stille speaker is op zichzelf geen bewijs van niet uitgevoerd.
3. Stop indien nodig lokaal bewust alle effecten en kies **Nieuwe ronde / herstel**. Wis geen groepen of events.
4. Alleen als regie daadwerkelijk heeft vastgesteld dat de fysieke finale niet is uitgevoerd: gebruik de lokale kaart **Onzekere finale: lokale controle nodig**, controleer de exacte groep en poging-ID, bevestig de fysieke niet-uitvoering en leg een reden van 10–200 tekens vast. Dit is de uitsluitend lokale regieactie `resolve_finale_not_executed`; zij bestaat niet in de internetallowlist.
5. De beslissing blijft duurzaam geaudit en het oude receipt wordt expliciet blocked/niet uitgevoerd. De oorspronkelijke groepsbinding wordt hersteld, zonder cue of volgende-Heks-vrijgave. Start het programma en meld de finale opnieuw gereed via de normale lokale voorwaarden. Pas daarna kan een **nieuwe bewuste** app-/actorhandeling een nieuwe poging maken. De zakelijke bezoekersscan en avonddeadline blijven intact.

Een `started`-slot kan nooit als niet uitgevoerd worden vrijgemaakt. Een verdwenen groep kan niet stilzwijgend worden hermaakt door deze herstelactie. Laat die situatie door organisatie/regie onderzoeken. Het wissen van historische slots, aanpassen van de database of hergebruiken van een andere groepscode is geen normale herstelhandeling.

## Uitrol en testbewijs

Pas uitsluitend toe op de exacte meegeleverde baseline in een aparte wijzigingsset en volg de bestaande bevoegde releaseprocedure. Deploy relay en bridge samen voordat actorbediening wordt geactiveerd. Bouw de relayimage met het aangepaste Dockerfile; draai één worker. Start de bridge eerst in SIMULATIE en controleer de feature-negotiatie, eigen controls, intrekking en readonly receipts. Gebruik bestaande synthetische tests en geen echte uitnodigingen/mails.

De bestaande reverse proxy blijft zonder toegevoegde POST-retries. Voeg ook in jobs, fetchwrappers, serviceworkers of reconnect geen commandoreplay toe. Er is wel een zakelijke app-/mailverwerking; deze bridge maakt geen bezoekersscans, avonddeadlines of e-mails.

Voor hardwarevrijgave blijven een afzonderlijke bevoegde locatieproef, echte QLC/audio-outputbevestiging, gecontroleerde bekabeling en veilige lokale werkwijze nodig. De meegeleverde unittests en ASGI/WSS-proeven zijn uitsluitend softwarebewijs. Deze wijzigingsset heeft geen echte Art-Net-output, audio-output, rook, productie-uitrol, Google-login of mailbezorging getest.
