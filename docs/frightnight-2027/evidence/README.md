# Browserbewijs FrightNight 2027

De actuele beelden en JSON-rapporten hieronder zijn gemaakt op de lokale **productiebuild** `eRSyuhMgvmTFYkX3lfRR3` met echte GoTrue-sessies en de geïsoleerde lokale database `frightnight_2027_dev`. De uitvoering staat als UTC-tijd in ieder JSON-rapport; 02:57 UTC is 03:57 in Europe/Amsterdam. De stagingrelease, bijbehorende Git-SHA en gepubliceerde controles worden afzonderlijk vastgelegd in de implementatiestatus en het stagingacceptatierapport.

| Proef | Resultaat | Bewijs |
|---|---|---|
| Publieke Playwrightsuite: 320, 390, 430, 768, 1024 en 1440 px; zonder JavaScript; minder beweging; toetsenbord; echte inloggrenzen; geen spontane OTP; openbare inhoud bij geblokkeerde database; PWA/noodinformatie | 16 geslaagd | `pnpm exec playwright test --config playwright.frightnight.config.ts`, laatste uitvoering 3 november 2026 omstreeks 02:57 UTC |
| Zes echte lokale accounts: twee gezinnen, bewoner, hoofdbeheer, activiteitmedewerker en betalingsbeheer; 320/390/1440 px | Geen overloop of paginafouten | [Rol-, identiteits- en cachecontrole](browser-authenticated/report.json) |
| Gelijktijdige start van twee gezinnen, capaciteit, offline handmatige scan, tweede tab wijzigt de route, herstel na 409, echte HTTP 503, dezelfde opdracht opnieuw, geen dubbele beloning, tijdpauze en heropening | 27 geslaagd | [Herstel- en mutatieproeven](browser-authenticated/mutation-report.json) |
| Bevoegdheden, smalle activiteitentoewijzing, eigen editie kopiëren, expliciete uitnodiging, serverprijs, contractcheckout, dubbele betaalwebhook en afgeschermd mailvoorbeeld | 22 geslaagd | [Nieuwe beheer- en betaalflow](browser-authenticated/new-ui-report.json) |
| Duurzaam bevestigd contact, synthetische locatie vraagt nieuwe beoordeling, correcte weigering vóór goedkeuring, echte regiegoedkeuring, tijdpauze en heropening | 6 geslaagd | [Bewoner- en beoordelingsflow](browser-authenticated/resident-review-report.json) |
| Openbare schermen en inloggrenzen op 390/1440 px | Geen overloop of paginafouten | [Publieke schermafbeeldingen](browser-public/report.json) |

## Beelden

| Ervaring | Telefoon | Desktop |
|---|---|---|
| Publieke v7-website | [390 px](browser-public/home-390.png) | [1440 px](browser-public/home-1440.png) |
| Deelnemer met echte actuele serverroute | [390 px](browser-authenticated/familyA-nachtpas-390.png) | [1440 px](browser-authenticated/familyA-nachtpas-1440.png) |
| Bewoner | [390 px](browser-authenticated/resident-mijn-zone-390.png) | [1440 px](browser-authenticated/resident-mijn-zone-1440.png) |
| Avondregie | [390 px](browser-authenticated/admin-avondregie-390.png) | [1440 px](browser-authenticated/admin-avondregie-1440.png) |
| Testcentrum | [390 px](browser-authenticated/testcentrum-390.png) | [1440 px](browser-authenticated/testcentrum-1440.png) |
| Echte betaalbevestiging uit de testsink, zonder bezorging | [390 px](browser-authenticated/testmail-preview-390.png) | [1440 px](browser-authenticated/testmail-preview-1440.png) |

In dezelfde map staan de deelnemertabs Nachtpas, Plein, Samen, Gegevens en Hulp, de verschillende regietabs, de tijdpauze, offline conflictherstel, de gekopieerde editie en de herkenbare contractcheckout. In screenshots zijn uitgegeven uitnodigings- en QR-codes afgeschermd waar ze anders zichtbaar zouden zijn.

## Betekenis en grenzen

Deze proeven gebruiken echte lokale servercommands, transacties, Auth en databaseautorisatie. Browseruitval is daadwerkelijk met `BrowserContext.setOffline(true)` opgewekt. De 503-proef onderschept één HTTP-response; hervatten stuurt vervolgens dezelfde opdracht naar de echte server. Een tweede onafhankelijk aangemelde browsercontext wijzigt werkelijk de serverroute vóór de 409-proef. Cachecontrole omvat een echte wissel tussen twee GoTrue-accounts, terugnavigatie en het vrijgeven van een opgehouden oude serverresponse nadat de identiteit is geïnvalideerd.

De betaalprovider in deze lokale ronde is de herkenbare contractadapter. Alleen het bevoegde testcentrum heeft de providerbevestiging nagespeeld. Dit bewijst geen externe Mollie-testbetaling. Mailbeelden zijn echte eventgebonden sinkrecords; er is geen bericht extern bezorgd. De bewonerslocatie is een expliciete synthetische testcoördinaat en bewijst geen PDOK-adrescontrole of echte straatvalidatie. Camera op fysieke telefoons, fysieke Lichtbakenhardware, externe pushbezorging, een belastingproef op de VPS en de uiteindelijke stagingrelease worden hiermee niet als uitgevoerd geclaimd.

De oudere map `browser/` bevat beelden uit de eerdere ontwikkelcontrole. Gebruik voor de actuele ervaring de bovenstaande mappen `browser-public/` en `browser-authenticated/`.
