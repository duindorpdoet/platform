# Afzonderlijke bridge-/relaywijziging

Tekstpatch tegen het originele `Duinpad-Showpakket-2.0.0.zip`, SHA256 `e3dc2a5d47c0376484fc60391ffe81cabbeb624d159850ae3d1644179d761622`. Dit pakket bevat geen gedupliceerde media en geen gewijzigde productie-installatie.

De patch bevat de actoradapter aan relay én bridgekant, versie-/eventonderhandeling, korte HMAC-autorisatie met actuele revisions, beperkte zonestops, gefilterde status en readonly receipts inclusief exact gedeeld finaleherstel na acteursintrekking, een duurzaam gedeeld QR2/Finale-GO-slot, lokale expliciete unknown-afhandeling en aanvullende simulatieregressies. Het originele manifest wordt bijgewerkt; het originele baseline-testrapport blijft bewaard naast `TESTRAPPORT-ACTOR-V1.json`.

Patch SHA256: `332d2cbc26f0d8257d7e6cf61d5cddb44f5a35a8be73f02cc1aad08dd8a0a26b`. [patch-manifest.json](./patch-manifest.json) bevat per gewijzigd/nieuw bestand de checksums vóór en na toepassing.

Controleer eerst tegen een **aparte uitgepakte baselinekopie**:

```bash
python3 apply-and-verify.py /pad/naar/aparte/Duinpad-Showpakket --check
```

Toepassen op die beoordeelde kopie:

```bash
python3 apply-and-verify.py /pad/naar/aparte/Duinpad-Showpakket
```

Het script bewaakt de patchchecksum en alle betrokken bronbestanden vóór schrijven en controleert de resultaatbestanden. Bij lokale wijzigingen stopt het; behoud die wijzigingen en reconcileer ze expliciet. Er wordt geen runtimebestand, credential, audio, QLC-project of hardware aangestuurd.

Testcommando vanuit de gepatchte showmap, in een eigen Python-omgeving met de bestaande requirements plus optionele relaytestafhankelijkheden:

```bash
python -m unittest discover -s tests -v
python -m compileall -q bridge deploy/relay_app.py
node --check web/app.js
```

Resultaat: **112/112 tests geslaagd**, waarvan 72 bestaande regressies en 40 nieuwe adapter-/relaytests. Exacte code-identiteit: bovenstaande patchchecksum; appcheckoutbasis `db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`. De toen gebruikte Python 3.12.3 en geïsoleerde dependencies staan in [test-environment.txt](./test-environment.txt). Geen requirements of packages in de bron zijn opgewaardeerd.

Zie [testresultaten](./TESTRAPPORT-ACTOR-V1.json), [volledige simulatie-uitvoer](./unittest-simulation.log), [patch-toepassingsbewijs](./apply-verification.log) en [protocol, configuratie, uitrol en herstel](./PROTOCOL-EN-HERSTEL.md).

Alle effectproeven gebruikten SIMULATIE; relay/WSS-tests draaiden in proces. Echte productie-uitrol, hardware, Art-Net, rook, mail en Google zijn hiermee niet bewezen. De concrete app-/relay-/showcomputerconfiguratie en bestaande releaseprocedure blijven nodig vóór geautoriseerde livevrijgave.
