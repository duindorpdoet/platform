# Avondverbeteringen: werkstatus 24 oktober 2026

Dit is een onvoltooide implementatiebranch. De bredere avondwijzigingen zijn niet op staging of productie gezet. De aparte, geteste hotfix voor eenvoudig startpunten bevestigen staat in PR 39, release `1622eb447f3a57546ef13c656bc71bfe5b848af7`.

## Afgeronde clientwerkzaamheden

- Bestaande versleutelde IndexedDB-opdrachten blijven behouden. De queue gebruikt atomische 12-secondenleases, een aanvraagdeadline van acht seconden en zes automatische pogingen met 1/2/4/8/16 seconden backoff. Account-, event-, groep- en runbinding blijven bij de oorspronkelijke opdracht; onbekende/corrupte gegevens worden behouden en niet verstuurd.
- Regressies voor twee tabbladen, accountwisseling tijdens herstel, ontbrekende authenticatie en een onderbroken zesde poging zijn afgedekt. Nagekeken opdrachten blijven terug te vinden, zonder credentialmateriaal in de UI.
- Offlineweergave gebruikt uitsluitend een geldige eigen cache. Verlopen of verkeerd gescopeerde cache toont opnieuw proberen en hulp. Opslagweigering kan afmelden en het pauzeren van de queue niet blokkeren.
- Buitenmodus is een aparte voorkeur per account. De huidige vrijgegeven bestemming toont huiswaarschuwingen, toegankelijkheid, spanning en aankomstvenster.
- Cockpitactualiteit wordt per gegevensbron bijgehouden. Laatste goede resultaten blijven zichtbaar bij een gedeeltelijke fout; oude antwoorden worden genegeerd.
- Zoekbare omleiding/afmelding, routebeoordeling, gereedheid en praktische huisinformatie hebben clientbediening, busy-/foutweergave en waar nodig expliciete herbeoordeling na een versieconflict.
- Nieuwe huisinformatie onderscheidt onbekend van expliciet geen extra effecten. Bestaande lege checkboxes worden niet als een bewuste verklaring geïnterpreteerd.

## Nog niet geïmplementeerde servercontracten

De client verwijst vooruit naar onderstaande RPC's. Zij bestaan nog niet in productie. Deze branch mag daarom niet als voltooide release worden uitgerold.

- `api.admin_route_command_options(_run_id)` voor actuele poortkeuzes, verantwoordelijke volwassenen en de runversie.
- `api.admin_startregie_review_route(...)`, routefingerprints en de uitgebreide publicatievoorwaarde `_expected_route_fingerprints`.
- `api.admin_evening_readiness(_event_slug)` en `api.record_evening_readiness(...)`: privé append-only bewijs, daadwerkelijke actor, autorisatie en actuele publicatie-/credentialrevisie.
- `api.portal_visit_information(_portal_id)` en `api.portal_visit_information_save(...)`, plus atomische opname in intake en organisatiebeheer.
- Live routeklok, gedeelde fysieke capaciteit, stabiele gepubliceerde finalereservering, vroeg/laat-scanconflicten en consistente lockvolgorde voor alle muterende ingangen.

De clienttypen zijn het voorlopige contract. Serverimplementatie en tests moeten dit bevestigen of de client samenhangend aanpassen. Geen clientstatus geldt als bewijs van serverautorisatie, capaciteit, een fysieke QR-test of een gelopen route.

## Productiebaseline en uitrolblokkade

Productiehealth toont `c892999bea664f1bf848b0435a262d930872d5f8`; de laatst geslaagde productiebackup bij die release omvatte 179 tabellen, 52 Storage-objecten en 80 migraties. Een nieuwe uitsluitend-lezen inventaris moet op de productiebranch onder het bestaande productie-environment worden uitgevoerd zodra de infrastructuurwijziging uit PR 39 daar staat. Behoud de bestaande branch- en environmentgrenzen.

Hotfix-CI 40042138038 is volledig geslaagd. Stagingrun 40042293666 doorliep backup/herstel, migratie en vergelijking van bestaande data, maar verloor de self-hosted runner bij de VPS-deploy. Nieuwe stagingrun 40044095260 doorliep opnieuw backup/herstel en wacht op de offline service `dg-sites-vps-01-duindorphalloweenstg-01`. Er is geen SSH-/servicebeheer beschikbaar in deze sessie. De gebruiker is gevraagd de service te laten herstarten. Er is geen productiepromotie uitgevoerd.

De drie lege, via de CLI gemaakte migratieplaatsaanduidingen zijn buiten de repository bewaard in `/tmp/duindorp-evening-unfinished-migrations`. Zij bevatten geen implementatie en zijn niet toegevoegd aan de gereviewde releaselijst. Maak de werkelijke migraties via de CLI en valideer de exacte releaselijst voordat de release wordt gepubliceerd.

## Verificatie en resterend bewijs

Gerichte tests voor queue/cache/huisinformatie: 26 geslaagd. Lint en typecheck zijn geslaagd. De eerste volledige applicatietestrun signaleerde terecht de drie lege, niet-gereviewde migratiebestanden; na het apart bewaren daarvan en de aanvullende cacheproeven slaagde de definitieve `pnpm verify`: lint, typecheck, 370 applicatietests in 53 bestanden, productiebuild en client-artifactscan van 1.168 bestanden.

Nog vereist: echte servercontracten en pgTAP, autorisatie- en concurrentieproeven, browserdoorlopen met echte Auth/RPC op 360/390/430px, stagingbelasting en databehoudvergelijking, productiepromotie en health op exact dezelfde SHA. De fysieke proef met geprinte posters, verschillende telefoons en een gecontroleerde wandel-/wacht-/finaleroute kan niet als browserbewijs worden afgevinkt. De echte IMAP-ontvangsttest is op expliciet gebruikersverzoek overgeslagen; zij is niet als geslaagd gerekend. OPS-03/mailworker blijft buiten scope.
