# Browserbewijs FrightNight 2027

De basisronde hieronder is gemaakt op de lokale **productiebuild** `eRSyuhMgvmTFYkX3lfRR3`. De aanvullende REG-01/REG-02-ronde draait op `3DJIV2_RRsuC8OdOesRkc` en vervangt het bewijs voor de gewijzigde regielijsten en doelgroepberichten. De laatste gerichte productronde gebruikt de lokale standaloneproductiebuild `C6R3bIB_R-40R-R5IjGPU` voor verhaaluitklap, programma- en voorwaardenpublicatie, contactprivacy, SVG-Nachtpas, operationele noodkaartjes en editiebrede regietotalen. De finale rustige-instelling- en downloadklokherproef draait op `VpdIRkZaItVoBhFIowORv`; de overige 42 gerichte accountchecks behouden hun eerdere, nog relevante buildcontext. De aangemelde rondes gebruiken echte GoTrue-sessies en de geïsoleerde lokale database `frightnight_2027_dev`. De uitvoering staat als UTC-tijd in ieder JSON-rapport; 02:57 UTC is 03:57 in Europe/Amsterdam. De stagingrelease, bijbehorende Git-SHA en gepubliceerde controles worden afzonderlijk vastgelegd in de implementatiestatus en het stagingacceptatierapport.

| Proef | Resultaat | Bewijs |
|---|---|---|
| Publieke Playwrightsuite: 320, 390, 430, 768, 1024 en 1440 px; zonder JavaScript; minder beweging; toetsenbord; echte inloggrenzen; geen spontane OTP; openbare inhoud bij geblokkeerde database; PWA/noodinformatie | 23 geslaagd op `VpdIRkZaItVoBhFIowORv`, inclusief verhaal, aanvullingen/fallback en rustige voorkeur na herladen/navigatie/in andere tabs/opslagweigering | [Laatste publieke browserronde](browser-public/public-review-report.json) |
| Zes echte lokale accounts: twee gezinnen, bewoner, hoofdbeheer, activiteitmedewerker en betalingsbeheer; 320/390/1440 px | Geen overloop of paginafouten | [Rol-, identiteits- en cachecontrole](browser-authenticated/report.json) |
| Gelijktijdige start van twee gezinnen, capaciteit, offline handmatige scan, tweede tab wijzigt de route, herstel na 409, echte HTTP 503, dezelfde opdracht opnieuw, geen dubbele beloning, tijdpauze en heropening | 27 geslaagd | [Herstel- en mutatieproeven](browser-authenticated/mutation-report.json) |
| Bevoegdheden, smalle activiteitentoewijzing, eigen editie kopiëren, expliciete uitnodiging, serverprijs, contractcheckout, dubbele betaalwebhook en afgeschermd mailvoorbeeld | 22 geslaagd | [Nieuwe beheer- en betaalflow](browser-authenticated/new-ui-report.json) |
| Duurzaam bevestigd contact, synthetische locatie vraagt nieuwe beoordeling, correcte weigering vóór goedkeuring, echte regiegoedkeuring, tijdpauze en heropening | 6 geslaagd | [Bewoner- en beoordelingsflow](browser-authenticated/resident-review-report.json) |
| Openbare schermen en inloggrenzen op 390/1440 px | Geen overloop of paginafouten | [Publieke schermafbeeldingen](browser-public/report.json) |
| Contactgegevens bewaren, conflict vanuit tweede tab, extra volwassen contactpersoon en kruistoegang, echte SVG/print en noodkaartjes, 516 inschrijvingen tegenover begrensde lijst van 100, rolgebonden metrics, programma/voorwaarden concept en publicatie via het regieformulier | 42 geslaagd op `C6R3bIB_R-40R-R5IjGPU`, geen paginafouten | [Gerichte productacceptatie](browser-authenticated/contact-metrics-svg-report.json) |
| SVG, HTML-print en beide noodpakketten: werkelijke downloadtijd apart van de editieklok, privacy/no-store, rolgrens zonekaartjes en echte offline weergave van de gedownloade bestanden | 24 geslaagd op `VpdIRkZaItVoBhFIowORv` | [Definitieve downloadherproef](browser-authenticated/download-clock-report.json) |
| REG-01/REG-02: vijf serverlijsten met elk 65 testregels, paging 50/15, zoeken buiten pagina 1, samengestelde filters en exacte totalen; organisatiebericht maken en doelgroep wijzigen | 70 geslaagd, geen paginafouten | [Gerichte regieacceptatie](browser-authenticated/regie-filter-audience-report.json) |

## Beelden

| Ervaring | Telefoon | Desktop |
|---|---|---|
| Publieke v7-website | [390 px](browser-public/home-review-390.png) | [1440 px](browser-public/home-review-1440.png) |
| Verhaaluitklap met personages | [390 px](browser-public/story-open-390.png) | [1440 px](browser-public/story-open-1440.png) |
| Vaste testvoorwaarden, ook zonder aanvullende publicatie | [390 px](browser-public/terms-static-fallback-390.png) | [1440 px](browser-public/terms-static-fallback-1440.png) |
| Eigen contactgegevens | [390 px](browser-authenticated/contact-form-390.png) | [1440 px](browser-authenticated/contact-form-1440.png) |
| Gedownloade zelfstandige SVG-Nachtpas | [390 px](browser-authenticated/nachtpas-svg-clock-390.png) | [1440 px](browser-authenticated/nachtpas-svg-clock-1440.png) |
| Editiebrede geautoriseerde servermetrics | [390 px](browser-authenticated/metrics-server-totals-390.png) | [1440 px](browser-authenticated/metrics-server-totals-1440.png) |
| Programma- en voorwaardenaanvulling beheren | [390 px](browser-authenticated/content-programme-terms-390.png) | [1440 px](browser-authenticated/content-programme-terms-1440.png) |
| Deelnemer met echte actuele serverroute | [390 px](browser-authenticated/familyA-nachtpas-390.png) | [1440 px](browser-authenticated/familyA-nachtpas-1440.png) |
| Bewoner | [390 px](browser-authenticated/resident-mijn-zone-390.png) | [1440 px](browser-authenticated/resident-mijn-zone-1440.png) |
| Avondregie | [390 px](browser-authenticated/admin-avondregie-390.png) | [1440 px](browser-authenticated/admin-avondregie-1440.png) |
| Testcentrum | [390 px](browser-authenticated/testcentrum-390.png) | [1440 px](browser-authenticated/testcentrum-1440.png) |
| Echte betaalbevestiging uit de testsink, zonder bezorging | [390 px](browser-authenticated/testmail-preview-390.png) | [1440 px](browser-authenticated/testmail-preview-1440.png) |
| Regie: serverfilters en globale totalen (nieuwste regiebuild) | [390 px](browser-authenticated/reg01-registrations-390.png) | [1440 px](browser-authenticated/reg01-registrations-1440.png) |
| Regie: gerichte organisatieberichten (nieuwste regiebuild) | [390 px](browser-authenticated/reg02-announcements-390.png) | [1440 px](browser-authenticated/reg02-announcements-1440.png) |

In dezelfde map staan de deelnemertabs Nachtpas, Plein, Samen, Gegevens en Hulp, de verschillende regietabs, de tijdpauze, offline conflictherstel, de gekopieerde editie en de herkenbare contractcheckout. In screenshots zijn uitgegeven uitnodigings- en QR-codes afgeschermd waar ze anders zichtbaar zouden zijn.

## Betekenis en grenzen

Deze proeven gebruiken echte lokale servercommands, transacties, Auth en databaseautorisatie. Browseruitval is daadwerkelijk met `BrowserContext.setOffline(true)` opgewekt. De 503-proef onderschept één HTTP-response; hervatten stuurt vervolgens dezelfde opdracht naar de echte server. Een tweede onafhankelijk aangemelde browsercontext wijzigt werkelijk de serverroute vóór de 409-proef. Cachecontrole omvat een echte wissel tussen twee GoTrue-accounts, terugnavigatie en het vrijgeven van een opgehouden oude serverresponse nadat de identiteit is geïnvalideerd.

De betaalprovider in deze lokale ronde is de herkenbare contractadapter. Alleen het bevoegde testcentrum heeft de providerbevestiging nagespeeld. Dit bewijst geen externe Mollie-testbetaling. Mailbeelden zijn echte eventgebonden sinkrecords; er is geen bericht extern bezorgd. De bewonerslocatie is een expliciete synthetische testcoördinaat en bewijst geen PDOK-adrescontrole of echte straatvalidatie. Camera op fysieke telefoons, fysieke Lichtbakenhardware, externe pushbezorging, een belastingproef op de VPS en de uiteindelijke stagingrelease worden hiermee niet als uitgevoerd geclaimd.

De oudere map `browser/` bevat beelden uit de eerdere ontwikkelcontrole. Gebruik voor de actuele ervaring de bovenstaande mappen `browser-public/` en `browser-authenticated/`.

De aanvullende regieproef zoekt en pagineert echte lokale inschrijvingen, zones, betalingen, hulpvragen en organisatieberichten. Zoekcriteria gaan uitsluitend in de JSON-body van een begrensde POST-aanvraag. De beheerder wijzigt hetzelfde bericht achtereenvolgens van algemeen naar Worteltocht, een expliciet gezelschap en één actuele routebestemming. Beide echte testaccounts lezen daarna hun serverprojectie; een zonebericht verdwijnt zodra de bestemming is vrijgegeven. De grotere lijsten zijn expliciete synthetische databasefixtures van uitsluitend een verse testeditie en bewijzen geen externe betalingen of adresvalidatie.

De laatste publieke suite controleert de weergave van de lichte publicatieprojectie met een expliciet benoemde responsefixture; dit bewijst op zichzelf geen databasepublicatie. Die grens is afzonderlijk met echte regieformuliercommands en de lokale publieke databaseprojectie getoetst: concepten ontbreken, gepubliceerde programma- en voorwaardenaanvullingen verschijnen. De vaste tochtvensters en versie `2027-test-v1` blijven in de servergerenderde pagina aanwezig wanneer deze optionele uitbreiding uitvalt. De contact- en metricproef gebruikte een verse eigen lokale editie en sloot uitsluitend die editie na afloop; contacten, Auth en audit-/financiële historie zijn behouden. Er is geen mail of externe betaalprovider aangeroepen. Het SVG-aandenken is ook als [daadwerkelijk gedownload bestand met afzonderlijke werkelijke tijd en editieklok](browser-authenticated/nachtpas-download-time.svg) beschikbaar.

De blijvende rustige instelling bevat uitsluitend een publieke aan/uitvoorkeur (`frightnight-calm-v1`). De browserproef wisselt werkelijk tussen de homepage en private ingang, herlaadt beide voorkeurstoestanden, synchroniseert twee tabs via native storage-events en weigert daarna browseropslag expliciet. De geheugenfallback houdt de bediening bruikbaar wanneer bewaren niet is toegestaan; systeemvoorkeur voor minder beweging blijft voorgaan. Dit bewaart geen identiteit, betaling, route, bevoegdheid of voortgang.
