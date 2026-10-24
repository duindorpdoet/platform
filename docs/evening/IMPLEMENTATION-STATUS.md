# Avondverbeteringen: werkstatus 24 oktober 2026

Dit is een onvoltooide implementatiebranch. De bredere avondwijzigingen zijn niet op staging of productie gezet. De aparte, geteste hotfix voor eenvoudig startpunten bevestigen staat in PR 39, release `ce23ab3564b6157ebfcb64c62d1edec4b11d0c8f`. PR 39 is gemerged; de volledige productie-uitrol en afzonderlijke externe smokecontrole zijn geslaagd. De hotfix is live.

## Afgeronde clientwerkzaamheden

- Bestaande versleutelde IndexedDB-opdrachten blijven behouden. De queue gebruikt atomische 12-secondenleases, een aanvraagdeadline van acht seconden en zes automatische pogingen met 1/2/4/8/16 seconden backoff. Account-, event-, groep- en runbinding blijven bij de oorspronkelijke opdracht; onbekende/corrupte gegevens worden behouden en niet verstuurd.
- Regressies voor twee tabbladen, accountwisseling tijdens herstel, ontbrekende authenticatie en een onderbroken zesde poging zijn afgedekt. Nagekeken opdrachten blijven terug te vinden, zonder credentialmateriaal in de UI.
- Offlineweergave gebruikt uitsluitend een geldige eigen cache. Verlopen of verkeerd gescopeerde cache toont opnieuw proberen en hulp. Opslagweigering kan afmelden en het pauzeren van de queue niet blokkeren.
- Buitenmodus is een aparte voorkeur per account. De huidige vrijgegeven bestemming toont huiswaarschuwingen, toegankelijkheid, spanning en aankomstvenster.
- Cockpitactualiteit wordt per gegevensbron bijgehouden. Laatste goede resultaten blijven zichtbaar bij een gedeeltelijke fout; oude antwoorden worden genegeerd.
- Zoekbare omleiding/afmelding, routebeoordeling, gereedheid en praktische huisinformatie hebben clientbediening, busy-/foutweergave en waar nodig expliciete herbeoordeling na een versieconflict.
- Nieuwe huisinformatie onderscheidt onbekend van expliciet geen extra effecten. Bestaande lege checkboxes worden niet als een bewuste verklaring geïnterpreteerd.

## Lokaal geïmplementeerde servercontracten

`api.admin_evening_readiness` en `api.record_evening_readiness` zijn lokaal geïmplementeerd. Bewijs is privé en append-only, met serveractor, actuele publicatie-/credentialrevisie, oorspronkelijke idempotentiesleutel en serverhash. Adminopeningen leveren geen deelnemerswaarneming op. Bestaande echte tutorialafrondingen tellen mee; handmatige verklaringen veranderen geen waargenomen gezinnentelling. Een latere negatieve verklaring blijft zichtbaar en krijgt voorrang op een oudere positieve handmatige verklaring. Een fysieke QR-attestatie vereist de huidige korte code plus expliciete print-/telefooncheckboxes; de code zelf blijft buiten het bewijs. De beheerweergave toont per gezin wat daadwerkelijk is waargenomen.

De praktische poortinformatie heeft nu één privé opslag met onderscheid tussen onbekend, expliciet geen extra effecten en opgegeven waarschuwingen. Eigen beheer en organisatiebeheer gebruiken de bestaande poortversie; intake heeft daarnaast een informatieversie. Een verouderde intake of herbeoordeling wist geen nieuwere bewonersinformatie. Oude positieve gegevens blijven bruikbaar, maar oude false-defaults worden geen verklaring dat er geen effecten zijn. Alleen de bestaande geautoriseerde projectie van de actuele bestemming wordt verrijkt; ouders krijgen geen algemene poort-ID-lookup. De al bestaande inclusieve aankomst-/zegelketen blijft behouden.

Een schone opbouw van uitsluitend de eigen lokale teststack plus alle pgTAP-tests is geslaagd: 1.998 controles in 74 bestanden, waaronder 51 gereedheids- en 40 poortinformatiecontroles. Onderwerpen van gereedheidsbewijs hebben echte FK-relaties: verwijderen archiveert een poort met bewijs, zonder verweesde records. Actor- en revisielabels zijn leesbaar; de onderliggende serveridentiteit blijft bewaard.

Vier aanvullende browserproeven met echte lokale Auth/RPC zijn geslaagd: eigen waarneming plus handmatig contact/focusherstel op 360/390/430 px; bewonersinformatie tot de actuele ouderbestemming; de bestaande organisatieflow voor bewerken/verwijderen; en een echte HTTPS-posterflow. De laatste bewijst PDF-generatie als afzonderlijke actie en precies één verklaring na een verloren antwoord ná servercommit. Dit is een synthetische UI-attestatie en geen fysieke drukwerk-/telefoonproef. De screenshots voor gereedheid en bezoekwaarschuwingen zijn bekeken. Volledige lint, typecheck, 377 applicatietests in 54 bestanden, productiebuild en artifactscan van 1.054 bestanden zijn geslaagd.

Een aanvullende echte parallelle databaseproef is geslaagd: een tocht starten en een eigen waarneming opslaan wachten zonder deadlock op dezelfde eventgrens. Een tijdens die wachttijd ingetrokken beheerrol kan daarna geen handmatige verklaring vastleggen. De proef controleert daadwerkelijke lockcontentie en behoud van de oorspronkelijke groep/run/bewijsstand na rollback en het opruimen van uitsluitend de tijdelijke testactor. Zij staat in de CI-keten.

De productie-inventaris is vóór deze implementatie vastgelegd. Deze twee serveruitbreidingen staan op de werkbranch; de resterende route-/capaciteitscontracten moeten aansluiten voordat de avondrelease wordt uitgerold.

## Transacties en veilig afmelden

De routegerelateerde ingangen, planning, groepssamenstelling, locaties en poortstatus volgen nu dezelfde volgorde: eventrij met `NO KEY UPDATE`, de bestaande dispatchmutex, actor/opdrachtsleutel en daarna run/groep/poort. De bestaande functie-bodies zijn statisch overgenomen; er vindt op de doelomgeving geen herschrijven van `pg_proc`-tekst plaats. Onafhankelijke voorraad- en printacties behouden hun eigen pad. De timer voor automatisch hervatten kiest eerst het evenement en controleert daarna opnieuw welke poorten nog gepauzeerd zijn.

Runhandelingen vereisen een daadwerkelijke verwachte versie. Veilig afmelden controleert de actuele live/gepauzeerde run en een op dit moment geregistreerde volwassene. Bestaande aankomsten, zegels, betalingen en credentials blijven exact behouden; een afgeronde of al gestopte tocht kan niet opnieuw worden afgemeld.

Een schone lokale opbouw plus de volledige regressiesuite is geslaagd: 2.020 pgTAP-controles in 75 bestanden. De bestaande echte parallelle Startregieproef met twee geauthenticeerde planners/publiceerders is groen. De aanvullende parallelle proef bewijst ook dat voorraad en poortstatus elkaar niet via hun event-FK vastzetten. Deze transactiewijziging staat nog op de werkbranch; ETA, fysieke capaciteit, finalereserveringen en routefingerprints volgen hierop.

## Nog niet geïmplementeerde servercontracten

De client verwijst vooruit naar onderstaande RPC's. Zij zijn nog niet geïmplementeerd. Deze branch mag daarom niet als voltooide release worden uitgerold.

- `api.admin_route_command_options(_run_id)` voor actuele poortkeuzes, verantwoordelijke volwassenen en de runversie.
- `api.admin_startregie_review_route(...)`, routefingerprints en de uitgebreide publicatievoorwaarde `_expected_route_fingerprints`.
- Live routeklok, gedeelde fysieke capaciteit, stabiele gepubliceerde finalereservering, vroeg/laat-scanconflicten en consistente lockvolgorde voor alle muterende ingangen.

De clienttypen zijn het voorlopige contract. Serverimplementatie en tests moeten dit bevestigen of de client samenhangend aanpassen. Geen clientstatus geldt als bewijs van serverautorisatie, capaciteit, een fysieke QR-test of een gelopen route.

## Productiebaseline en uitrol

Hotfix-CI [40052620685](https://github.com/duindorpdoet/platform/actions/runs/40052620685) en volledige staging-uitrol [40052812221](https://github.com/duindorpdoet/platform/actions/runs/40052812221) zijn geslaagd op exact `ce23ab3564b6157ebfcb64c62d1edec4b11d0c8f`. De stagingproef omvatte een verse versleutelde backup, geïsoleerd herstel, migrations, databehoudvergelijking, VPS-uitrol en healthcontrole. De productiebranch is daarna fast-forward gepromoveerd. Productie-uitrol [40054456261](https://github.com/duindorpdoet/platform/actions/runs/40054456261) is geslaagd. De afzonderlijke externe health-/routecontrole bevestigt live dezelfde SHA.

De stagingrunner viel uit doordat de VPS-schijf vol was. De gebruiker maakte 3,5 GB vrij met apt-cache- en journaldonderhoud. Afgebakend onderhoud van uitsluitend de staging Git-checkout verkleinde vervolgens `.git` van 11,60 GiB naar 244,36 MiB, met ongewijzigde HEAD en bronbestanden. Er is nu ongeveer 14,63 GiB vrij. Releases, runtime, opslag en database werden hierbij niet gewijzigd. Maintenance-runs tellen niet als geslaagde stagingrelease.

De uitsluitend-lezen productie-inventaris [40054582474](https://github.com/duindorpdoet/platform/actions/runs/40054582474) is geslaagd op 24 oktober 2026 om 02:42:37 UTC: 81 migraties, 179 tabellen en 482 functies. Alle functiehashes komen exact overeen met de lokale testbasis. Het ZIP-artifact is op SHA-256 gecontroleerd. De private inventaris bevat schema, migrationversies, functiehashes en databehoudfingerprints zonder rijinhoud of credentials. Deze werkelijke baseline is vastgesteld vóór implementatie van nieuwe servercontracten. Behoud de bestaande branch- en environmentgrenzen.

De drie lege, via de CLI gemaakte migratieplaatsaanduidingen zijn buiten de repository bewaard in `/tmp/duindorp-evening-unfinished-migrations`. Zij bevatten geen implementatie en zijn niet toegevoegd aan de gereviewde releaselijst. Maak de werkelijke migraties via de CLI en valideer de exacte releaselijst voordat de release wordt gepubliceerd.

## Verificatie en resterend bewijs

De huidige clientcheckpoint heeft 377 geslaagde applicatietests in 54 bestanden, volledige lint, typecheck, productiebuild en een client-artifactscan van 1.054 bestanden. Naast de bestaande queueproeven zijn echte opgeslagen bevestigde receipts van de oude productieversie als regressiefixture getest: zij blijven leesbaar en worden nooit opnieuw verzonden. Onzekere opdrachten zonder oorspronkelijke sleutel blijven ongewijzigd bewaard voor controle.

Drie aanvullende browserproeven met echte lokale Auth/RPC zijn geslaagd: bestaande offline/reconnect/camera-afhandeling; een aflopend snapshot met een duurzaam bewaarde aankomst; en buitenmodus na herladen en een echte accountwisseling. De laatste twee doorlopen controleerden 360/390/430 px. De synthetische screenshots staan in `docs/evening/screenshots/` en zijn bekeken. Een verlopen bestemming verdwijnt ook als de telefoon continu offline blijft. Fout-/hulpinformatie blijft zichtbaar boven de aankomsthistorie. Snapshot-, auth- en formulieraanvragen hebben een begrensde wachttijd; een onbekende uitkomst wordt niet als bevestigde aankomst voorgesteld.

Nog vereist: de resterende route-/capaciteitsservercontracten en pgTAP, bijbehorende autorisatie- en concurrentieproeven, volledige geïntegreerde browserdoorlopen met echte Auth/RPC op 360/390/430px, stagingbelasting en databehoudvergelijking, productiepromotie en health op exact dezelfde SHA. De fysieke proef met geprinte posters, verschillende telefoons en een gecontroleerde wandel-/wacht-/finaleroute kan niet als browserbewijs worden afgevinkt. De echte IMAP-ontvangsttest is op expliciet gebruikersverzoek overgeslagen; zij is niet als geslaagd gerekend. OPS-03/mailworker blijft buiten scope.
