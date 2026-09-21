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

## Releasevoorwaarden

- Staging moet de remote migraties, Supabase security advisors, Sites-VPS-rooktest, signed SendGrid Event Webhook en echte OTP/IMAP-proef groen afronden.
- Productie accepteert uitsluitend exact die succesvolle stagingcommit.
- Productie-inschrijving blijft gesloten totdat B-001 en B-002 expliciet zijn opgelost; deze implementatie verandert dat niet automatisch.
- Bulkmail, DNS-wijzigingen en het verwijderen van productiegegevens blijven buiten scope.
