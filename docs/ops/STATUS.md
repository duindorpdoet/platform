# Startregie, groepsbeleid en noodzakelijke evenementberichten

De productie-uitgangssituatie voor deze uitbreiding is `401abf29869b241f1c90e1bdad04be001ef514f3`. Het eerdere volledige redesign is op 23 oktober 2026 als exact geslaagde stagingversie gepromoveerd: [PR 35](https://github.com/duindorpdoet/platform/pull/35), [productie-uitrol](https://github.com/duindorpdoet/platform/actions/runs/39984512314). De live healthcontrole en publieke/beschermde routecontroles bevestigden deze versie. De oorspronkelijke overdrachtbaseline `bc2b3796` is historische herkomst.

De aanvullende wijziging staat in [PR 36](https://github.com/duindorpdoet/platform/pull/36). De lokale integratieproeven hieronder zijn geslaagd. CI, de beschermde herstelproef en de exacte staging-/productiepromotie moeten nog worden afgerond; dit bestand is nog geen productieacceptatie voor de uitbreiding.

## Overgenomen bron en gedrag

De aanvullende overdracht heeft referentiecommit `e2bff0bd8575595257a39d65284d8dba43ad9f94`. Alle 464 aangeleverde SHA-256-regels zijn gecontroleerd. De drie referentie-Node-suites slagen met 36 tests. De HTML-galerij is geopend en de originele beelden zijn op hun eigen afmetingen bekeken. De referentie blijft een prototype met fictieve gegevens; deze implementatie gebruikt de bestaande Next-app, Auth, private database, transacties en workers.

- Het korte Startregie-pad staat boven het uitgebreide planbord. Concept, bevestiging en publicatie zijn aparte handelingen. De publicatie bewaart een onveranderlijke kopie van punt en slot. Een gewijzigde locatie maakt een nieuwe werkrevisie en trekt de loopcontrole in.
- Deelnemers lezen een gedeelde serverprojectie: hun eigen gepubliceerde tijd staat vooraf vast; naam, adres en coördinaten van het eerste startpunt volgen vanaf exact T−60. Een vertrekcommando controleert de eigen starttijd. Oudere publicatiecommando's kunnen de revisiecontrole niet omzeilen.
- Nieuwe gecontroleerde huizen zijn kandidaten voor het resterende traject. Het huidige doel en afgeronde bezoeken blijven staan. De bezoekgrens telt een werkelijk bereikt huis ook als alle kinderen buiten blijven. Een onbereikte systeemoverslag telt niet mee. Tijdvensters en fysieke capaciteiten blijven zelfstandige grenzen.
- De evenementlimiet is een positief geheel aantal kinderen, ook 30 of 45. Registratie, samenlopen en planning lezen dezelfde instelling. Verlaging verwijdert, splitst of depubliceert geen bestaande groep. Opslaan vraagt een actuele versie, impactcontrole, reden en waar nodig expliciete beoordeling van uitzonderingen.
- Belangrijke en urgente **evenementberichten** kunnen naar huidige en nieuwe deelnemers worden verzonden, ook als gewone e-mailupdates uitstaan. Nieuwsbriefvoorkeuren, intrekkingen en toestemmingsregistraties worden niet veranderd. Deze release verstuurt zelf geen mededeling.
- Pushregistratie en daadwerkelijke verzending gebruiken exacte provider-origins, volledige P-256-controle, maximaal vijf actieve apparaten, tien accountgebonden schrijfverzoeken per minuut, maximaal twintig doelen en drie gelijktijdige pogingen. Ook mislukte invoer verbruikt een verzoek. Dezelfde budgetten worden gedeeld door de bestaande pushkanalen. Metadata toont geen apparaatkeys of bestemmingstokens.

OPS-03 blijft buiten de wijziging. Bestaande mailleases, retrybeleid, betaal- en webhookpaden blijven behouden. Twee gerichte mailwijzigingen zijn functioneel nodig: de expliciet gevraagde noodzakelijke evenementberichten en het opnieuw projecteren van startafspraken bij uitlezen van oude wachtrijberichten, zodat oude payloads geen vroeg adres lekken.

## Beveiliging en gegevensbehoud

De release gebruikt 22 expliciet benoemde migratiebestanden: de vier reeds uitgerolde redesign-expansies en achttien nieuwe aanvullingen. Backup en preflight vergelijken precies deze geordende lijst en de SHA-256 van ieder bestand. Een ontbrekend, dubbel, anders geordend of extra toekomstig bestand wordt geweigerd. De versleutelde volledige database-/Storagebackup, Vault-herstelproef, netwerkloze migratieproef en vergelijking van oorspronkelijke kolommen/rijen blijven verplicht.

Er is geen productiereset, reseed, automatische aankomstbackfill of QR-rotatie. Bestaande gepubliceerde afspraken worden uitsluitend naar de nieuwe private publicatietabel gekopieerd. De gebruikersvoorkeuren en consentvelden krijgen geen backfill. De cacheversie voor oude private groepssnapshots verandert; bestaande aankomstopdrachten en hun idempotentiesleutels blijven intact.

De geïsoleerde lokale proeven gebruiken uitsluitend het eigen Supabase-project `duindorp-ops-codex-20261023`. Fictieve eerder gepubliceerde startafspraken worden voor aankomstregressies als afzonderlijke, al bereikbare testafspraak toegevoegd. Er is geen productieklokoverride.

## Huidig bewijs en nog uit te voeren

Na een volledige opbouw vanuit alle 22 gereviewde releasemigraties: **1.840 databasecontroles in 69 bestanden geslaagd**. Daarin zitten 42 Startregiegrenscontroles, 49 pushservercontroles, 25 nieuwe-huis-/tijdproeven, 17 controles voor de volledige 45-kindketen en 8 voor het gekoppelde starthuis. Verder slagen 355 unitcontroles in 52 bestanden, ESLint, TypeScript en de productiebuild.

Echte Auth-/API-proeven slagen voor 14 + 12 kinderen bij limiet 30, weigering bij 25, behoud bij verlaging en één beleidscommit bij twee gelijktijdige beheerders. De afzonderlijke Startregie-raceproef gebruikt twee echte Auth-clients: één plancommit en één stale-input-conflict, veilige exacte replay, geen gedeeltelijk gemengd plan, behoud bij onmogelijke fysieke capaciteitsverlaging, precies één publicatie bij twee schrijvers en atomaire afwijzing van een onvolledige batch.

Drie echte browserproeven slagen voor concept/bevestiging/publicatie/herladen, privé-route en ouderpayload, groepsbeleid 30/45/impact, push-HTTP-quota/rate/metadata en de mobiele fout-/focusbediening. Een afzonderlijke HTTPS-browsertest bewijst de echte mobiele lijst met 45 kinderen, een eigen boek met één daadwerkelijk verdiend zegel en een gedownloade persoonlijke PDF. Desktopbeelden zijn 1348 × 926; mobiele beelden zijn 390 en 360 breed. Zie [validatiemapping en bewuste visuele verschillen](VALIDATIE.md).

Deze lokale proeven vervangen geen stagingacceptatie. De volledige bestaande regressies draaien in CI. Productiepromotie volgt uitsluitend op de exact geslaagde staging-SHA en de versleutelde backup-/herstelproef met vergelijking van oorspronkelijke data. De expliciet overgeslagen echte IMAP-ontvangsttest wordt niet als geslaagd gerapporteerd; de standaardtest blijft ingeschakeld voor gewone deploys.

Fysieke looproutecontrole, QR-camera-/printerproeven en bezorging op afzonderlijke echte testapparaten zijn niet uitgevoerd in deze ontwikkelomgeving. Een gecontroleerde node/edge in een synthetische fixture is geen straatproef.

De Node HTTPS-grens gebruikt de versleuteling/VAPID-opbouw van de geïnstalleerde `web-push`-bibliotheek. De eigen verbinding valideert publieke DNS-antwoorden, volgt geen redirects en gebruikt een abortsignaal voor de volledige poging; alleen een sockettimeout begrenst geen volledige response. Zie de [Node 24 HTTP-documentatie](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html#requestdestroyerror) en de geïnstalleerde bibliotheekbron `node_modules/web-push/src/web-push-lib.js` voor de gecontroleerde runtimegrenzen.
