# Beheerindiening en lokale oefenavond — 28 oktober 2026

Deze integratie bouwt voort op production `86629f35` en behoudt de later uitgerolde realtime- en P-38-hotfixes (`5b8cdaa8`). De Sites-versie is alleen als interactiereferentie gelezen. Er worden geen prototypebackend of browsermocks uitgerold. De echte P-42 is niet als testaanvraag gebruikt of door deze release automatisch ingediend.

## Voor de organisatie

Open **Poorten → Aangemelde poorten**, open de betreffende aanvraag en kies **Namens bewoner indienen**. De actie verschijnt uitsluitend bij een bestaande conceptaanvraag of gevraagde aanpassing en expliciete `portals_manage`-toegang. Vier ingevulde categorieën betekenen nog geen indiening.

De actuele preview toont de aanvraag, bewoner, blokkerende indieningsgegevens en afzonderlijk wat vóór goedkeuring nodig is. Vul herstelbare gegevens aan via **Aanmeldgegevens aanvullen**. Ontbrekende bewonersverificatie, waarschuwingen of toestemming laat de bewoner via de bestaande eigen route vastleggen. Er wordt nooit toestemming ingevuld namens de bewoner.

Controleer een nieuwe preview na bewerken, geef een reden van 10–500 tekens en bevestig bewust de indiening. **Annuleren** verandert niets. Na bevestigde indiening wordt de aanvraag **Klaar voor beoordeling**; de tijdlijn vermeldt **Namens bewoner ingediend door organisatie**. Goedkeuren, locatiecontrole en activeren blijven aparte stappen. Een onzekere netwerkuitkomst toont **Uitkomst controleren** en herhaalt dezelfde opdracht met dezelfde sleutel; controleer anders de actuele aanvraag en tijdlijn.

De auditactor blijft de beheerder; de aanvrager en ontvanger blijven de geverifieerde bewoner. Het bestaande berichttype `portal_received` gaat eenmaal per aanvraag/indienversie naar de bestaande outbox. Voor deze release zijn geen echte bewoners als mailtest gebruikt.

### Vastgestelde afwijking in het oude goedkeuringspad

De huidige resident-submit uit `20260927142219_poortkamer.sql` staat ontbrekende adres-/belevingsdetails en niet-bevestigde `availability`/`locationConsent` toe. Dit indiencontract blijft behouden in een gedeelde private validator. De goedkeuringswrapper uit `20260924193000_approve_houses_with_contact_and_address.sql` bleek de toestemmingscontrole uit `20260924144126_simplify_house_registration.sql` over te slaan. Conform de gevraagde scheiding herstelt deze integratie de expliciete beschikbaarheids- en locatietoestemming **alleen bij goedkeuring**. Reeds goedgekeurde poorten worden niet geconverteerd of uitgezet. Ontbrekende operationele voorkeuren blijven bij goedkeuring de bestaande defaults houden.

SQL 040 test daarom voortaan minimale contact-/adresgegevens **met expliciete toestemming**, zonder extra operationele details. SQL 093 bewijst apart dat indienen zonder die toestemming wel kan en goedkeuren dan blokkeert. Dit is een bewuste wijziging van de effectieve goedkeuringscontrole, geen aanscherping van indiening en geen ingevulde toestemming.

## Voor poortwachters

Ga naar **Meer → Voorbereiden → Oefenen**. Start de oefenavond en kies de coach of vrij oefenen. Open de oefenpoort, ontvang fictieve groepen, bevestig hun aankomst en rond hun bezoek af. Daarna kun je drukte, pauze, een lokaal bericht, hulp, hervatten en afsluiten oefenen. Het bezoek en het zegel tellen ieder slechts eenmaal per fictieve groep.

Een poortpauze houdt nieuwe instroom tegen; een reeds naderende of ontvangen groep kan worden afgehandeld. Hervatten laat de eerste wachtende groep door wanneer de oefenpoort vrij is. De optionele oefenfinale heeft geen effect op het echte Poortenboek.

De badge **Oefenstand — fictieve groepen** blijft zichtbaar tijdens scrollen. De oefenknoppen sturen geen echte avond-, serveroefening-, chat-, hulp-, incident-, mail- of pushopdrachten. De gewone Poortkamerbediening buiten de oefening blijft haar eigen echte betekenis en bestaande rechten houden.

Voortgang bestaat alleen in geheugen van dit tabblad, onder `duindorp.portal-practice.memory.v1:<event>:<portal>:<user>`, met maximaal acht contexten. Wisselen van onderdeel en nieuwe snapshots behouden de lopende oefening; herladen of sluiten begint opnieuw. Er is geen browseropslag of synchronisatie tussen apparaten. **Opnieuw** vraagt bevestiging en wist alleen deze fictieve oefening. Animaties respecteren verminderde beweging; reset ondersteunt focusvastzetting en Escape.

## Servergrens en regressie

Migratie `20261028002257_admin_submit_portal_application.sql` voegt afzonderlijke preview/apply-RPC's toe. Beide toetsen eventgebonden `portals_manage`; `event_admin` alleen is onvoldoende. De preview is alleen-lezen en geeft een beperkt DTO. De hash bindt draft, aanvraagstatus/versie, geverifieerde bewonersidentiteit, geclaimde/niet-ingetrokken intake, gekoppelde poortstatus/versie en validatiebeleid. Er wordt geen route- of planbordhash berekend.

Apply vergrendelt in de lifecyclevolgorde event → bevoegdheid/opdrachtsleutel → intake → aanvraag → poort → identiteit. Het command past alleen indieningsvelden aan. Requesthash en receipt zijn gekoppeld aan actor + `portal.admin.submit` + sleutel. Een replay controleert opnieuw toegang en actuele bewoners-/intake-/poortcontext, retourneert daarna de oorspronkelijke receipt vóór de stale-versiecontrole. Andere payload bij dezelfde sleutel geeft conflict. Residentauthenticatie blijft het afzonderlijke eigenaarpad gebruiken.

De lokale acceptatie gebruikt uitsluitend herkenbaar fictieve accounts in een geïsoleerde Supabase-stack. SQL 093 vergelijkt alle overige domeintabellen en Auth-tabellen vóór/na; de browsertest van de oefening vergelijkt echte poortstatus, `run_stops`, reserveringen, paspoortzegels, gesprekken, incidenten, mail/push-outboxes en de oude serveroefentabellen. Alleen de vier bedoelde tabellen mogen bij beheerindiening wijzigen: aanvraag, audit, ontvangstoutbox en commandreceipt.

Lokaal gecontroleerd: lint, TypeScript, productiebuild, 546 unitchecks (één bestaande skip), een verse volledige SQL-run met 2.368 controles en daarna de definitieve SQL 093 met 58 controles. De vier nieuwe beheerbrowsertests slagen, inclusief een verloren antwoord na commit, stale preview, herstelpad en echte gelijktijdige RPC's. De oefenavond slaagt op alle vijf Poortkamerconfiguraties: desktop, Samsung-formaat, iPhone/WebKit, tablet en 320px met verminderde beweging. De bestaande status-/checklist-/offlineproef slaagt eveneens op alle vijf. CI herhaalt de volledige suites voor de releasecommit, inclusief de laatste twee extra SQL-autorisatiecontroles.

Visuele voorbeelden bevatten uitsluitend lokale fixtures: [desktop](../screenshots/poortkamer/room-desktop-oefenstraat.png), [mobiel](../screenshots/poortkamer/room-samsung-chrome-oefenstraat.png), [iPhone](../screenshots/poortkamer/room-iphone-webkit-oefenstraat.png).

## Release en capaciteit

De migratie staat in de bestaande beoordeelde staging/production-migratieset. Release gebruikt de bestaande volledige CI, versleutelde backup met geïsoleerde herstelproef, staging en daarna exact dezelfde SHA naar production. De door de gebruiker verleende hosted mailvrijstelling moet aan die exacte SHA en een beperkte geldigheidsduur zijn gebonden; ze bewijst geen hosted mailaflevering. SQL-/outbox-, software- en browsercontroles blijven verplicht.

Deze wijziging verhoogt geen Supabase-quota of databasepool. De actuele, nog onbewezen hosted belastingacceptatie en de acceptatieaanpak voor 31 oktober staan in [HALLOWEEN-CAPACITEIT-2026.md](./HALLOWEEN-CAPACITEIT-2026.md). De 254 testidentiteiten blijven een testomvang, geen vastgestelde verwachte gelijktijdigheid. Productiecapaciteit boven de eerder vastgestelde staginglimieten wordt hiermee niet bewezen.
