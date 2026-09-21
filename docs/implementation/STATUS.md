# Implementatiestatus

Laatst bijgewerkt: 2026-09-21 (Europe/Amsterdam)

## Huidig checkpoint

- Werkbranch: `build/duindorp-productie` vanaf `main` (`e66c260`).
- Ontwerpbron: pakket 1.3, prototypeversie 4, ontwerpcommit `612b4cc4d4273c4ed9759ec53653c894229250f8`.
- Pakketcontrole: geslaagd; 170 bestanden en prototypeversie 4 geverifieerd.
- Lokale appverificatie: lint, strict TypeScript, 14 unit-tests, productiebuild en 18 Playwright-tests op desktop/mobiel geslaagd.
- Lokale databaseverificatie: 5 migraties vanaf nul, 51 pgTAP-tests en schemalint geslaagd.
- Doelruntime: Next.js standalone via de bestaande self-hosted Sites-VPS-pijplijn.
- Live inschrijving: blijft gesloten volgens `run-config.json`.

## Gebouwde productdelen

| Fase | Status | Bewijs |
|---|---|---|
| Preflight en bronport | gereed | Packageverificatie, GitHub environments/runners en versie-4-assets gecontroleerd. |
| Publieke ervaring | lokaal groen | Volledige routematrix, privacyveilige sfeerkaart, responsieve homepage en toegankelijke motion-control. |
| Auth en autorisatie | lokaal groen | Echte zescijferige Supabase OTP-flow, cookieverversing, capability-RPC’s en negatieve DB-contracten. |
| Registratie, huis en betaling | gebouwd | Persistente wizards, serverprijs, capaciteit, Tikkie-handcontrole, samenloop en portaleigenaarprojectie. |
| Planning en live tocht | gebouwd, aanvullende matrixproeven open | Deterministische planner, versieerbare publicatie, verborgen toekomstige stops en transactionele scan/skip/advance. |
| Mail en jobs | lokaal groen | SendGrid Auth-hook, outboxworker, pg_cron, retries, signed Event Webhook en monotone statusafleiding. |
| PWA/realtime/privacy | lokaal groen | Network-only privéflows, begrensde gebruikerssnapshot, private channels/buckets en no-store headers. |
| CI/CD | gereed voor eerste run | CI plus afgebakende staging- en production-workflows met exacte-commitgate en provideracceptatie. |
| Staging | nog uit te voeren | Eerst committen/promoveren; workflow voert remote migraties, advisorchecks, OTP/IMAP en rooktests uit. |
| Productie | gate gesloten | Alleen na groene staging van exact dezelfde commit; registratie blijft gesloten. |

## Niet als operationeel gereed aangemerkt

Echte poorten, gecontroleerde loopverbindingen, startmomenten, routevoorstellen, definitieve groepsgrenzen en goedgekeurde juridische teksten zijn niet aangeleverd. Daarom publiceert het systeem geen echte route en wordt de productie-inschrijving niet geopend. Zie `BLOCKERS.md` en de criteriumspecifieke matrix.
