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

### B-005 — Transactionele organisatie-notificatie opnieuw verifiëren

Stagingrun `35806175214` bewijst echte OTP-ontvangst en succesvolle verificatie tegen Supabase Auth. De transactionele proef faalde doordat de test op de oude bezoekersbevestiging wachtte, terwijl de beveiligde contactflow uitsluitend het vaste organisatiedoel mailt. De vervolgfix configureert op staging `TEST_EMAIL_1` als vast doel en controleert `Nieuw contactbericht`. De echte bezorgingsproef na deze fix staat nog open. Historische SendGrid-blockregistraties zijn geen permanente suppressions.

### B-006 — Opgelost: signed SendGrid Event Webhook beschikbaar

Stagingrun `35806175214` configureert de app-specifieke signed webhook en accepteert de provider-testrequest. De oudere melding over een bezet slot is niet meer actueel. Productie blijft de ondertekende webhook verplicht controleren tijdens promotie.

### B-007 — Beperkte SendGrid-sleutelscope nog niet aangetoond

MAIL-05 vereist bewijs dat de verzendsleutel uitsluitend de benodigde mailrechten heeft en daarmee echt kan verzenden. In het huidige acceptatiedossier ontbreekt dat scopebewijs; deze lokale hervatting heeft de providerrechten niet onderzocht. Een bevoegde accountbeheerder moet de rechten controleren en de bezorgingsproef moet na oplossing van B-005 worden afgerond.

## Releasevoorwaarden

- Staging moet de remote migraties, Supabase security advisors, Sites-VPS-rooktest, signed SendGrid Event Webhook en echte OTP/IMAP-proef groen afronden. B-005 verhindert de volledige stagingacceptatie momenteel.
- Productie accepteert uitsluitend exact die succesvolle stagingcommit.
- Productie-inschrijving blijft gesloten totdat B-001 en B-002 expliciet zijn opgelost; deze implementatie verandert dat niet automatisch.
- Bulkmail, DNS-wijzigingen en het verwijderen van productiegegevens blijven buiten scope.
