# Publieke browsercontrole van de gepubliceerde d843-release

Werkelijk uitgevoerd op https://staging-halloween.duindorpdoet.nl op 3 november 2026, 09:11–09:12 UTC, na de expliciete releasevrijgave. Onafhankelijke healthcontroles vóór en na de proef bevestigen HTTP 200, `ok`, `frightnight-2027-v7`, `frightnight-2027-test`, provider `contract` en exact SHA `d8439e09c67083548d8b09ac4110d24820a52dd0`.

- **24/24 permanente publieke browsertests** geslaagd, zonder overgeslagen tests, retries of flaky resultaat; werkelijk 28,0 seconden.
- **19/19 aanvullende visuele en native PWA-controles** geslaagd. De serviceworker activeerde en bestuurde de pagina echt. Offline herladen leverde onafhankelijke Duinpad-noodinformatie met zichtbaar, geladen en gedecodeerd logo. Privénavigatie bleef een `503` met `no-store`; caches bevatten geen privépagina of API-respons. Reconnect werkte.
- **Tien volledige screenshots** op 390 en 1440 pixels: home, geopend verhaal, voorwaarden, onaangeroerd inlogscherm en native offlinepagina. Vóór iedere opname is de volledige pagina doorgescrold en op laden, positieve afbeeldingsbreedte en native `decode()` gewacht. Alle tien beelden zijn daarna visueel bekeken, inclusief de Oogstdorpafbeelding en het offline logo.
- **Nul Auth-/OTP-, betaal-, mail-, push-, formulier-, databasecommand- of externe requests.** Geen accountcontext gebruikt. Browser/API-guards blokkeerden muterende en externe acties; geen verboden poging werd waargenomen.

Vóór het toelaten van een native serviceworkercontext zijn de gepubliceerde workerbytes vergeleken met `git show` van deze exacte SHA. Beide geven SHA-256 `fd5ae6c265834b4732ce85c17e67cd2304fc31666ad4769945ecba68e48e7b66`.

`report.json` bundelt de uitkomst en de bron-/beeldhashen. De oorspronkelijke Playwright-, visual/PWA- en releasebindingrapporten en de gebruikte guarded-harnessbronnen zijn meegeleverd. De tekstprojectieproef gebruikt alleen een lokale browserresponse voor presentatie; er is niets gepubliceerd of gewijzigd via de server.

Dit dossier is uitsluitend publiek browserbewijs. Het claimt geen resultaten voor de afzonderlijke geauthenticeerde parent-, Storage-, REG/EDGE-, load- of RET05-proeven, fysieke telefooninstallatie of camerabeeldherkenning.
