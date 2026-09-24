# Nachtregie redesign — stagingacceptatie

Deze wijziging brengt de organisatieomgeving, groepsomgeving en huisomgeving in lijn met de Sites-referentie. De bestaande processen blijven leidend; de nieuwe schermen gebruiken de actuele event-, poort-, groeps-, route- en messengergegevens.

## Acceptatiepunten

- De cockpit toont boven de vouw een 50/50-verdeling tussen de live poortenkaart en aandachtspunten/live log. Op mobiel staat de kaart boven de acties.
- Alleen goedgekeurde poorten met geverifieerde coördinaten verschijnen op de kaart. De kaart verzint geen positie voor ontbrekende locaties.
- Markers ondersteunen hover, tik en toetsenbordfocus. De popup toont code, naam, adres, contactpersoon, telefoonnummer, status en een actie naar de poort.
- Marker- en poortkaartgegevens komen uit `api.admin_portal_operations_snapshot`. Realtimeberichten bevatten uitsluitend identifiers; de client haalt daarna opnieuw de beveiligde projectie op.
- De poortenpagina toont contactpersoon, volledig adres, klikbaar telefoonnummer, bezoekindicatie en status op iedere kaart.
- Groepsindeling toont per inschrijving de kinderen, samenloopbundel, voorkeuren en het actuele groepstotaal. Organisatoren kunnen voor publicatie groepen maken en inschrijvingen slepen of via **Verplaats** indelen.
- Een gepubliceerde of live groep is vergrendeld. Een goedgekeurde samenloopbundel wordt atomair verplaatst en telt als éé geheel mee voor de limiet van maximaal 20 kinderen.
- De groepsomgeving toont groepscode, tijdvoorkeuren, gewenste laatste poort, voortgang en het poortenpaspoort zonder toekomstige adressen vrij te geven.
- De huisomgeving behoudt Open/Pauze/Gestopt, toegewezen groepen en verwachte aantallen.

## Autorisatie en privacy

De beheerkaart en poortkaarten lezen privéadres en contactgegevens uitsluitend via een `security definer` RPC met een expliciete controle op `event_admin`, `portals_manage` of `live_support`. Anonieme gebruikers, ouders en groepsdeelnemers hebben geen execute-recht of worden server-side geweigerd. Bewoners blijven aangewezen op de bestaande eigen-poortprojectie. De private realtime topic controleert dezelfde eventrollen en verstuurt geen adres- of contactvelden.

## Gegevens die beheerders nog kunnen moeten aanvullen

De staging-poortenpagina toont boven de lijst het actuele aantal **aan te vullen** kaarten. Iedere ontbrekende waarde staat permanent als **Niet ingevuld** op de betreffende kaart, met een actie om de bewoner via Messenger om correctie te vragen. Controleer voor lancering per goedgekeurde poort:

1. contactpersoon;
2. volledig adres;
3. telefoonnummer;
4. fysiek geverifieerde breedte- en lengtegraad;
5. juiste wereld en eventuele aanwijzing als laatste poort.

De stagingdata bepaalt welke concrete poorten in deze lijst vallen; er worden geen fictieve adressen of coördinaten toegevoegd.

## Validatie

- pgTAP: onbevoegde ouder kan kaartprojectie en groepsindeling niet lezen of wijzigen; beheerder kan dit wel.
- pgTAP: coördinaten komen in MapLibre-volgorde `[lengtegraad, breedtegraad]` terug.
- Playwright: marker hover, tik/klik, toetsenbordfocus, clustering, filteren, kaartuitval/herladen en externe realtime statuswijziging.
- Playwright: responsive navigatie en hoofdschermen voor organisatie, ouder/groep en huis op 320, 375, 390 en 430 px.
- `pnpm verify` en de volledige Supabase-testsuite moeten voor staging groen zijn.
