# Poortenboek V2 en Poortkamer V2

## Architectuur

Poortenboek V2 bouwt voort op de bestaande twaalfuurs kindersessie. De browser krijgt geen directe tabeltoegang. Identiteit, oefenpoort, teamnaam en vaandel lopen via `api.poortenboek_child_action`; het servercontract leidt kind en kindteam af uit de sessie. Een kindteam blijft de bestaande bevestigde `together_party`, onafhankelijk van de operationele wandelgroep.

Een afgeronde `run_stop` met een bevestigd bezoek is de gezaghebbende gebeurtenis voor echte voortgang. Eén database-trigger schrijft idempotent een zegel per aanwezig kind, één voortgangsrecord per kindteam en de toepasselijke verhaalhoofdstukken. Het zegel bewaart de actieve, goedgekeurde presentatieversie als immutable snapshot. Daardoor verandert een historisch Poortenboek niet wanneer een poort later een nieuwe presentatie activeert.

Poortkamer V2 blijft observerend voor routegroepen. Alleen de bestaande open-, pauze- en gestopt-contracten bedienen de planner. Wachtrij, bezoeklog en terugblik lezen de bestaande route- en bezoekstatussen. Presentaties, operationele incidenten en simulaties hebben aparte servercontracten; simulatierecords dragen altijd een `simulation_run_id` en schrijven niet naar bezoeken, zegels, chat, uitnodigingen of push-outbox.

## Migratie

`20260927222522_poortenboek_poortkamer_v2.sql` voegt toe:

- gecureerde avatar- en lantaarnkeuzes per kind;
- oefenpoortstatus, vaandelstemmen en berekende teamconfiguratie;
- idempotente teamvoortgang, paspoortzegels en zes verhaalhoofdstukken;
- versievaste poortpresentaties met review- en activatieworkflow;
- operationele incidenten en statushistorie zonder medische categorieën;
- volledig geïsoleerde simulatieruns en simulatie-events;
- expliciete huisteamrollen, los toegangsniveau en tijdelijke deactivering.

Alle nieuwe tabellen staan in `app_private`, hebben RLS aan en zijn niet rechtstreeks leesbaar voor `anon` of `authenticated`. Publieke uitvoering op interne helpers is ingetrokken. De browser gebruikt alleen de bestaande beperkte API-RPC's. Intrekken of tijdelijk deactiveren verandert de membership-epoch, waardoor nieuwe queries en nieuwe realtime-autorisaties onmiddellijk falen.

## Rollen

De Poortkamer ondersteunt Hoofdbeheerder, Poortbeheerder, Acteur, Ontvangst, Techniek en Alleen meekijken. Het toegangsniveau `read`, `live` of `manage` wordt apart opgeslagen en gecontroleerd. Oude `coadmin`- en `crew`-waarden blijven voor bestaande data compatibel.

## Communicatie en configuratie

Er zijn geen nieuwe environmentvariabelen of externe diensten nodig. De bestaande mail-outbox, pushvoorkeuren, private realtime-topics en feature-instellingen blijven leidend. Simulatie verstuurt geen echte mail of push. De Poortenpleinkanalen zijn Mededelingen, Voorbereiding, Decor en techniek, Hulp gevraagd en Tijdens de avond; historische kanaaldata blijft bewaard.

## Assets

De 40 aangeleverde WebP-assets staan onder `public/images/poortenboek-v2` en `public/images/poortkamer-v2`. Alle namen, datums, teamnamen, statussen, certificaattekst en statistieken worden als HTML of SVG gerenderd. Vaandelkleuren, vormen, symbolen en voortgangseffecten zijn programmeerbaar; rasterbeelden zijn alleen decoratief.

## Bewuste grenzen

V2 bevat geen kinderschat, multiplayergame, GPS, upload, AR, voorraadbeheer, snoepstatus, medische flow of routebediening vanuit de Poortkamer. De downloadbare herinnering en certificaten gebruiken de bestaande printweergave, zodat geen zware PDF-dependency nodig is.
