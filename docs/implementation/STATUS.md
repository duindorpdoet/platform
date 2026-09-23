# Implementatiestatus

Laatst bijgewerkt: 2026-09-23 (Europe/Amsterdam)

## Checkpoint 23 september — OTP en stagingmail

PR #8 is samengevoegd; stagingcommit `0163690` doorloopt CI succesvol (run `35806175430`). Deploymentrun `35806175214` bevestigt migraties, gateway, scheduler, security-advisors en HTTP-controles. De echte mailboxproef ontvangt een OTP en verifieert die succesvol tegen Supabase Auth.

De resterende mailfout is een verouderd acceptatiecontract: publieke contactformulieren maken sinds de beveiligingsmigratie alleen `contact_notification` voor het vaste organisatiedoel aan. De test wachtte op `contact_received` voor de bezoeker. Het vaste organisatiedoel was bovendien niet toegestaan door de stagingallowlist. De vervolgfix configureert het vaste stagingdoel als `TEST_EMAIL_1` en controleert de echte organisatie-notificatie. Productie gebruikt `ORGANIZATION_SUPPORT_EMAIL`. Alleen de deploymentrol kan dit doel configureren; acht databasecontracttests controleren die grens. Echte transactionele bezorging moet na deployment van deze fix nog slagen.

Onderstaande oudere checkpoints blijven historisch bewijs. Operationele vrijgavevoorwaarden en het gedeelde SendGrid-webhookslot zijn nog open.

## Huidig checkpoint

- Werkbranch: `build/duindorp-productie`; HEAD `95ae050` met aanvullende lokale, nog niet gecommitte wijzigingen. Laatst vastgelegde stagingdeployment: `c66798c`; deze hervatting heeft geen remote deployment uitgevoerd.
- Ontwerpbron: pakket 1.3, prototypeversie 4, ontwerpcommit `612b4cc4d4273c4ed9759ec53653c894229250f8`.
- Pakketcontrole: geslaagd; 170 bestanden en prototypeversie 4 geverifieerd.
- Lokale appverificatie: lint, strict TypeScript, 50 unit-tests, productiebuild en 24 publieke Playwright-tests op desktop/mobiel plus vijf aangemelde desktoptests geslaagd.
- Lokale databaseverificatie: 9 migraties vanaf nul, 338 pgTAP-tests en schemalint geslaagd.
- Aanvullende lokale acceptatie: Auth/OTP inclusief dubbele e-mailbevestiging en echte parallelle transacties geslaagd; productieclientscan controleert 587 bestanden.
- Doelruntime: Next.js standalone via de bestaande self-hosted Sites-VPS-pijplijn.
- Live inschrijving: blijft gesloten volgens `run-config.json`.

## Gebouwde productdelen

| Fase | Status | Bewijs |
|---|---|---|
| Preflight en bronport | gereed | Packageverificatie, GitHub environments/runners en versie-4-assets gecontroleerd. |
| Publieke ervaring | lokaal groen | Volledige routematrix, privacyveilige sfeerkaart, responsieve homepage en toegankelijke motion-control. |
| Auth en autorisatie | lokaal groen | Echte zescijferige Supabase OTP-flow, cookieverversing, capability-RPC’s en negatieve DB-contracten. |
| Registratie, huis en betaling | gebouwd | Persistente wizards, geadresseerde eenmalige gezinsuitnodigingen met intrekking, serverprijs, append-only terugbetaling, samenloop en geaudite QR-rotatie/download. |
| Planning en live tocht | gebouwd, aanvullende matrixproeven open | Deterministische intervalplanner, servergevalideerde graaf/capaciteit bij opslag en publicatie, verborgen toekomstige stops, transactionele scan/skip/advance, leiderwissel en aparte gesloten-poort-systemskip. |
| Mail en jobs | lokaal groen | SendGrid Auth-hook met bekende-actielijst, vaste organisatiedoelen voor publieke formulieren, outboxworker, pg_cron, retries, signed Event Webhook en monotone statusafleiding. |
| PWA/realtime/privacy | lokaal groen | Network-only privéflows, begrensde gebruikerssnapshot, private channels/buckets en no-store headers. |
| CI/CD | actief | CI plus afgebakende staging- en production-workflows met exacte-commitgate en provideracceptatie. |
| Staging | `c66798c` gedeployd, releasegate rood | Workflow `35643888861`: remote upgrade, Auth-hook, VPS, advisors en HTTP-smoke groen; beide testmailboxen staan op de gedeelde SendGrid-blocklijst en het Event Webhook-slot is bezet. |
| Productie | gate gesloten | Geen promotie zolang staging niet volledig groen is; registratie blijft gesloten. |

## Niet als operationeel gereed aangemerkt

Echte poorten, gecontroleerde loopverbindingen, startmomenten, routevoorstellen, definitieve groepsgrenzen en goedgekeurde juridische teksten zijn niet aangeleverd. Daarom publiceert het systeem geen echte route en wordt de productie-inschrijving niet geopend. Zie `BLOCKERS.md` en de criteriumspecifieke matrix.

## Hervattingscheckpoint 22 september

De bestaande lokale database bevatte gewijzigde browserfixtures, waardoor een directe pgTAP-run faalde. Na een lokale back-up en `supabase db reset --local` slagen alle 338 contracttests. Voer databasecontracten altijd na een reset uit; de Auth-, concurrency- en aangemelde browsertests wijzigen fixtures. Reset opnieuw vóór aangemelde browseracceptatie, zoals in CI.

Aanvullend afgerond: echte service-workerupdate tijdens onopgeslagen invoer; cameratracks opruimen bij sluiten/navigeren en late toestemming; wizardfout-/stapfocus en stoppen na een mislukte save; publieke en private schermen op smalle viewports inclusief alle beheeronderdelen. Gevonden clipping in beheer en juridische pagina’s is hersteld. Lint negeert nu tijdelijke Playwright-artefacten.

De 200-clientproef slaagt met 800 requests zonder fouten en precies één routeadvance: p95 305–430 ms voor snapshots en 434 ms voor identieke afrondingsverzoeken. Zie `load-acceptance-20260922.json`. Dit is lokaal bewijs met één gedeelde bevoegde identiteit, geen productielastmeting met 200 huishoudens. De proef is opgenomen in CI.

Nog open: volledige handmatige toegankelijkheidscontrole (UX-03), fysieke telefoon-/avondproef en externe releasevoorwaarden in `BLOCKERS.md`. Geautomatiseerde 200-procent-tekst- en basistoetsenbordchecks slagen, maar vervangen die handmatige controle niet.

## Correctie wereldenblok en mailcheck

De live homepage had geladen afbeeldingen die door ontbrekende CSS-regels achter de achtergrond verdwenen. De component gebruikt geen oude tabs-wrapper meer; de stylesheet is daarop aangepast. De grote wereldafbeelding, zes fototegels en actieve selectie zijn hersteld, met pijltjes-/Home-/End-bediening en horizontale selectie op mobiel. Nieuwe browserchecks doorlopen alle zes werelden, afbeeldinggeometrie, navigatie en detailkoppeling; desktop- en mobiele screenshots zijn visueel gecontroleerd.

De SendGrid-check classificeerde historische blocks onjuist als permanente suppressions. Die controlefout is hersteld en afwijsredenen worden geredigeerd gelogd. Zie de gecorrigeerde B-005; eerdere meldingen over een verplichte verwijdering van beide blocks waren niet juist. Lokale verificatie: 54 unit-tests en 20 homepage/publieke browserchecks geslaagd, plus lint, TypeScript en productiebuild.
