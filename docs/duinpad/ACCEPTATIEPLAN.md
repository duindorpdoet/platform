# Acceptatie en regressietests

Dit is een uitvoerbaar **testplan**, geen verklaring dat de productie-integratie al is getest. Alle onderstaande checks beginnen op **niet uitgevoerd**. Noteer per check de werkelijk geteste commit, omgeving, bewijsbestand en uitslag. Een geslaagde Sites-demo bewijst geen productie-authenticatie, mailaflevering of hardware-uitvoering.

**Lagen:** U = unit; API = authenticatie/HTTP; DB = database/integriteit; B = browser; S = relay/bridge in simulatie. Gebruik synthetische personen en een geïsoleerde testconfiguratie. Geen echte uitnodigingen, deelnemersmails, Art-Net-output of rook tijdens ontwikkeling. Een hardwareproef is een afzonderlijke, ter plaatse vrijgegeven stap.

## A. Identiteit en bestaande route — 6 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| A01 | API/DB | Client levert een andere groeps-ID aan. | Server gebruikt uitsluitend de eigen geautoriseerde evenement-/routegroepkoppeling; andermans aanvraag wordt geweigerd. |
| A02 | U/DB/S | QR1 en de finale worden door verschillende accounts uit dezelfde routegroep bevestigd. | Beide relay-aanvragen gebruiken exact dezelfde opgeslagen `group_id`; zichtbare groepsnamen bepalen deze niet. |
| A03 | DB | Samenloop heeft twee gezinnen; routegroep bevat daarnaast een zelfstandig account. | Party-ID bepaalt gedeeld scanrecht, routegroep-ID de deadline, household-ID de bedankjes. |
| A04 | API/B | Laatste gewone bezoek wordt bevestigd, eventueel met een geplande wachttijd. | Bestaande serverroute geeft de finale vrij op het juiste moment; geen vaste aanname van twintig bezoeken. |
| A05 | B/API | Alleen een QR-link openen of de code valideren. | Nog geen finalescan, deadline of showstart; expliciete aankomstbevestiging blijft noodzakelijk. |
| A06 | DB/B | Een aanwezig kind slaat de beleving over. | Bevestigde aankomst en zegel blijven behouden; deelnamekeuze blijft afzonderlijk zichtbaar. |

## B. Finale en gezamenlijke avondafsluiting — 7 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| B01 | DB/API | Eerste geldige finalescan wordt transactioneel geaccepteerd. | Eén servertijdstip en onveranderlijke deadline op exact +2 uur worden vastgelegd. |
| B02 | DB | Twee accounts/samenlopen scannen gelijktijdig. | Eén eerste groepsdeadline; iedere toegestane scan hoogstens eenmaal; geen race-afhankelijke verlenging. |
| B03 | API/DB | Herhaalde scan, dubbelklik of tweede account binnen dezelfde samenloop. | Bestaande ontvangst terug; geen extra scanrecht of nieuwe deadline. |
| B04 | DB/B | Later zelfstandig account uit dezelfde routegroep scant. | Eigen ontvangst toegestaan, eerste groepsdeadline blijft ongewijzigd. |
| B05 | U/DB/B | Eén milliseconde vóór, exact op en na de deadline. | Avond eindigt op de grens voor alle gekoppelde deelnemers, ook zonder eigen finalescan. |
| B06 | B/API | Browser was gesloten; gebruiker opent een eerder tabblad of logt opnieuw in. | Serverstatus opent het bedankscherm; browserklok, cache en lokale opslag zijn geen autoriteit. |
| B07 | DB/S | Finale-aankomst is geaccepteerd, maar relay blokkeert of antwoord ontbreekt. | Fysieke routeafronding en deadline blijven correct; UI beweert geen bevestigde showstart of volledige showvoltooiing. |

## C. Relay en fysieke uitvoering — 9 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| C01 | S | Bevestigde QR1. | Groep geregistreerd; geen audio, licht, showtijdlijn, twee-uursavondklok of automatische Heks GO; bestaande registered/prepare_s-voorwaarde blijft behouden. |
| C02 | S | QR2 met verkeerde groep of onvoldoende lokale voorwaarden. | Weigering zonder uitvoering; veilige bezoekersmelding; hetzelfde huidige finale-QR-moment wordt gebruikt. |
| C03 | S | QLC start wel, audio niet, of andersom. | Geen volledige start-ACK en geen volgende Heks-vrijgave; lokale herstelstatus wordt zichtbaar. |
| C04 | S | QLC én audio bevestigen start. | Eén finale; volgende Heks GO wordt lokaal vrijgegeven, maar nooit automatisch uitgevoerd. |
| C05 | API/DB/S | Meerdere accountscans plus handmatige `finale.go` tegelijk. | Gezamenlijk groepsslot en deduplicatie voorkomen een tweede voorstelling of extra vrijgave. |
| C06 | API/S | HTTP 200 met `ok:false`, daarna een bewuste nieuwe poging. | Eerste weigering telt niet als showstart; nieuwe attempt-ID toegestaan, bestaande bezoekersontvangst blijft dezelfde. |
| C07 | API/S | HTTP 504, `unknown:true`, afgebroken verbinding of request-timeout. | Uitkomst blijft onbekend; geen automatische retry, nieuw attempt-ID of verzonnen succes. Regie moet eerst reconciliëren. |
| C08 | S/B | HTTP 503, reconnect, verouderde opdracht of herstel van een opgeslagen route-aankomst. | Geen latere fysieke uitvoering; herstel mint geen verse `issued_at` voor een oude startintentie. |
| C09 | U/API/S | Tijdstempel ouder dan 20 s, verstreken actor-deadline, tijdsafwijking of foutieve scope. | Strikte afwijzing; 15 s client-/12 s relay-wachttijd blijft begrensd; status wordt eerlijk vertaald. |

## D. Acteurskamer en rechten — 10 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| D01 | API/DB | Uitnodigen zonder organisatiecapability of in een ander evenement. | Geen uitnodiging of rechtenwijziging. |
| D02 | DB/API | Geen uitnodiging, verkeerd e-mailadres, verlopen, ingetrokken of vervangen claimtoken. | Geen activatie; oude link ongeldig; veilige herstelroute. |
| D03 | B/API | Correcte OTP-login, Google-login, verkeerde Google-identiteit of annulering. | Alleen geverifieerde juiste identiteit kan expliciet claimen; veilige callback en accountwissel werken. |
| D04 | DB/API | Dubbele claim in tabs/callbacks; acteur bestaat al als ouder/bewoner. | Eén acteurskoppeling; geen dubbele auth-identiteit, deelname, betaling of poortaanmelding. |
| D05 | API/DB | Gewoon ingelogd account of client claimt rol/actor-ID/permission. | Login alleen geeft geen bediening; server bepaalt actuele identiteit en rechten. |
| D06 | B/API | Actor heeft uitsluitend `zone1.trigger`. | Alleen die knop zichtbaar; directe POST voor andere actie weigert eveneens. |
| D07 | B/API/DB | Rechten wijzigen of intrekken bij geopende app met bestaande JWT. | Snapshot verandert en iedere volgende actie controleert actuele rechten; oude JWT houdt rechten niet in stand. |
| D08 | S/API | Zone-stop of stop tijdens heks/finale. | Uitgevoerde scope klopt; globale stop vereist afzonderlijk recht en juiste benaming. |
| D09 | S/B | Knop toegestaan, maar heks/finale/herstelstatus blokkeert. | Knop toont reden; lokale controller handhaaft voorwaarden ondanks een directe aanvraag. |
| D10 | API/S | Dubbele actoropdracht, timeout, reconnect en handmatige finale. | Eén uitvoering; unknown blijft unknown; beperkte lokale actorrol; geen fabricage van bezoekersscan of +2-uursklok. |

## E. Bedankjes en mail — 6 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| E01 | DB/API | Bedankje voor niet-bereikte poort of voor andermans gezin. | Weigering; alleen eigen bevestigde aankomsten zijn beschikbaar. |
| E02 | DB/B | Bestaande drie keuzes opslaan en aanpassen. | Eén record per evenement/gezin/poort; geen vrije tekst of duplicaten; bewoners zien geen gezins-/kindnamen. |
| E03 | DB/API | Deadlineworker draait gelijktijdig, opnieuw of na storing. | Eén transactionele bedankmail per bedoelde deelnemer/account; geen tweede mail na herstart. |
| E04 | API/S | Mailprovider accepteert, bezorgt, weigert of geeft onzekere uitslag. | Bestaande mailstatussen en suppressies blijven gelden; geaccepteerd is niet bezorgd; geen blind opnieuw verzenden. |
| E05 | B/API | Afgesloten gezin opent Overzicht, Route of mailknop. | Eén samenhangende terugblik met bestaande bedankjes, Poortenboek en zegels; link vereist passende eigen toegang. |
| E06 | API/DB | Actoruitnodiging en bedankmail worden getest. | Synthetische outbox/mocks of uitdrukkelijk toegestane testadressen; geen ongeautoriseerde echte verzending. |

## F. Beveiliging, regressie en oplevering — 7 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| F01 | API | Verkeerde origin, ongeldige invoer, limietoverschrijding of vervalste scope. | Bestaande validatie, origin-/CSRF-controles, limieten en veilige fout-envelop werken. |
| F02 | U/build | Clientbundles, QR’s, foutmeldingen en auditlogs worden gecontroleerd. | Geen geheimen, OTP’s, claimtokens, cookies of onnodige persoonsgegevens. |
| F03 | B/S | Service worker, offlinegedrag en netwerkherstel. | Geen privéstatuscache of show-POST-replay; gewone bestaande routeherstelregels blijven intact. |
| F04 | B | 320/390 px, toetsenbord, schermlezer en reduced motion. | Bereikbare knoppen, begrijpelijke labels, focusherstel, geen horizontale scroll of noodzakelijke knipperanimatie. |
| F05 | API/B/DB | Bestaande ouder-, kinder-, Poortkamer-, betaling-, account- en routeflows. | Relevante bestaande regressies slagen; gesloten publieke inschrijving blokkeert geen acteursuitnodiging. |
| F06 | S/DB | Nieuwe module uitzetten, serverherstart en bridgeherverbinding. | Bestaande app blijft bruikbaar; geen automatische fysieke uitvoering of dubbele commandoroute. |
| F07 | CI/staging | Actuele checkout, migraties en bestaande releasechecks. | Exacte SHAs, uitgevoerde commands en resultaten vastgelegd; ontbrekende configuratie en onbewezen hardware/mail apart vermeld. |

## Bewijsregistratie en vrijgave

Bewaar per check: ID, commit(s) van app/relay/bridge, omgeving, simulatie of echte uitvoering, resultaat, tijd, bewijsreferentie en beperking. Noteer expliciet welke checks niet konden worden uitgevoerd. Een nieuwe simulatie kan bestaande hardwarebewijzen niet vervangen. Voor productie gelden daarnaast de bestaande repository-releasevoorwaarden en de expliciete autorisatie van de uitvoersessie.

## G. Extra grensgevallen uit de echte bridgebron — 6 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| G01 | API/DB/S | Meerdere accounts bevestigen dezelfde QR1-groepsaanmelding, ook later dan 20s. | Bestaande bevestigde registratie wordt hergebruikt; geen nieuwe group_add/event-ID voor dezelfde groep. |
| G02 | API/S | Receipt van een oude/unknown poging opvragen. | Apart gefilterd alleen-lezen pad; geen oude POST, verse timestamp of fysieke bijwerking; identiteit en payloadbinding worden gecontroleerd. |
| G03 | API/S | zone1/2/3 en hun stoprechten aanroepen. | Exact pad1/interne2, pad2/interne3, pad3/interne4; geen emergency-erfenis en geen interne1/5-zonestop zonder stop-all. |
| G04 | DB/API | Party verlaten, accounts/parties samenvoegen of beheerherindeling na eerste scan. | Geen nieuw scanrecht, deadlineverschuiving of opnieuw actieve avond; het vastgelegde cohort en audit blijven consistent. |
| G05 | API/S | Getekende actorpayload aanpassen, scope/args verruimen, expiry/revision verouderen of request onder andere actor herhalen. | Backend én bridge weigeren; oude autorisatie laat nog niet uitgevoerde opdrachten na intrekking niet door. |
| G06 | DB/S | App-/bridgeherstart, lokaal reset_groups en vertraagde deadlineworker. | Geen tweede groepsshow; scan-/deadline-/maildedupe blijven; snapshots weigeren nieuwe scans zodra de vaste deadline verstreken is, ook vóór workerverwerking. |

## H. Beide QR-posters en beheer — 2 checks

| ID | Laag | Situatie | Verwacht bewijs |
|---|---|---|---|
| H01 | API/DB/B | Organisatie opent Duinpad: QR1 & QR2; QR1 bestaat nog niet of is al gekoppeld. | Twee afzonderlijke kaarten met juiste checkpointfunctie; bevoegde aanmaak/koppeling waar nodig; geen automatische extra gewone stop, herplanning of demo-QR. Onbevoegden kunnen niets aanmaken/roteren. |
| H02 | API/B/S | Beide A4-posters downloaden, opnieuw downloaden en scannen via dezelfde routegroep; ook codes/stadia verwisselen. | QR1 meldt uitsluitend aan; QR2 vraagt alleen de juiste finale aan; verkeerde mapping weigert. Posters hebben QR1/QR2-labels, korte code en printactie; herhaald downloaden wijzigt geen credential. Werkende appcode en showverbinding zijn afzonderlijk zichtbaar. |
