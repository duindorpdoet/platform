# Blokkades en externe vrijgavevoorwaarden

## Actief

### B-001 — Operationele avonddata ontbreekt

De CSV-bronnen bevatten alleen headers. Echte poorten, gecontroleerde loopverbindingen, startmomenten, routevoorstellen, beheerders en sponsors zijn niet aangeleverd. Gevolg: geen echte routepublicatie en geen operationele vrijgave. De beheerimport gebruikt dry-run en expliciete publicatie; productie start veilig als `draft`.

### B-002 — Juridische inhoud is nog niet formeel goedgekeurd

Privacy- en voorwaardenpagina’s bevatten een functionele productsamenvatting, maar de definitieve versies/versienummers moeten door de organisatie worden vastgesteld voordat inschrijving open mag.

### B-003 — Fysieke avondproef ontbreekt

Camera, netwerkovergang, twee gelijktijdige telefoons, iOS/Android-PWA-update en de daadwerkelijke looproute vereisen een gecontroleerde praktijktest op locatie. Browseremulatie telt daarvoor niet als bewijs.

### B-004 — Kaartprovider niet geconfigureerd

Er is geen goedgekeurde MapLibre-style-URL/key aangeleverd. De publieke app toont daarom bewust alleen een lokale privacyveilige sfeerkaart zonder adressen; een echte providerstijl en attributie blijven geblokkeerd.

### B-005 — Beide toegestane testontvangers staan op de SendGrid-blocklijst

De ondertekende Supabase Auth-hook en SendGrid-API-configuratie zijn gedeployd, maar de providercontrole in stagingrun `35643888861` toont voor beide vooraf geautoriseerde testontvangers een bestaande `block`-suppression. De run-config verbiedt wijziging van bestaande gedeelde SendGrid-resources. Daardoor kan de echte OTP-/IMAP-bezorgingsproef niet slagen totdat een bevoegde accountbeheerder die twee suppressions beoordeelt en zo nodig verwijdert. De applicatie maskeert dit niet als succes.

### B-006 — Geen vrij SendGrid Event Webhook-slot

Het bestaande gedeelde SendGrid-account heeft één Event Webhook-slot en dat is al in gebruik door een andere consumer. Staging laat de bestaande webhook aantoonbaar ongemoeid en meldt een waarschuwing. Productie vereist de app-specifieke ondertekende webhook hard en blijft daarom gesloten totdat de accountbeheerder een vrij slot of een geïsoleerde subuser beschikbaar stelt.

## Releasevoorwaarden

- Staging moet de remote migraties, Supabase security advisors, Sites-VPS-rooktest, signed SendGrid Event Webhook en echte OTP/IMAP-proef groen afronden. B-005 en B-006 verhinderen dit momenteel.
- Productie accepteert uitsluitend exact die succesvolle stagingcommit.
- Productie-inschrijving blijft gesloten totdat B-001 en B-002 expliciet zijn opgelost; deze implementatie verandert dat niet automatisch.
- Bulkmail, DNS-wijzigingen en het verwijderen van productiegegevens blijven buiten scope.
