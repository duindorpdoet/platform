# Operationeel runbook

## Releasevolgorde

1. Laat CI groen worden op de te releasen commit.
2. Fast-forward exact die commit naar `staging`.
3. Controleer de GitHub deployment: migraties, Edge Function, Sites-release, Auth-config, Cron, security advisors, signed Event Webhook, OTP en transactionele testmail moeten groen zijn.
4. Controleer handmatig de staginghomepage, login en gesloten/allowlisted gedrag.
5. Fast-forward exact dezelfde SHA naar `production`. Een andere SHA wordt door de productionworkflow geweigerd.
6. Controleer `/api/health`: environment, revision en `registrationMode=closed`.

## Registratie veilig openen

Niet via een losse frontendvariabele. Eerst moeten echte operationele data, juridische versies en organisatiegoedkeuring aanwezig zijn. Pas daarna worden runtime `REGISTRATION_MODE=live` en een afzonderlijk geautoriseerd database-releasecommand samen gewijzigd. De huidige productionworkflow dwingt `closed` en `production_closed` af.

## Planning publiceren

1. Importeer bestanden eerst als dry-run en los alle rijmeldingen op.
2. Genereer een voorstel met vaste seed en controleer alle conflictcodes.
3. Laat een tweede bevoegde beheerder capaciteit, routevolgorde en vensters beoordelen.
4. Publiceer de geselecteerde planversies expliciet. Oudere versies en auditregels blijven bestaan.

## Mail controleren

- OTP loopt via Supabase Send Email Hook en SendGrid.
- Applicatiemail loopt via `email_outbox`; Supabase Cron roept `/api/jobs/mail` iedere minuut aan.
- HTTP 202 betekent alleen provideracceptatie. `delivered`, `bounce`, `dropped` en `spamreport` komen via de signed Event Webhook.
- Controleer bij problemen eerst jobconfig/schedule, leases, retrytijd, providerstatus en webhooksignature; verstuur geen bulkherhaling.

## Incident tijdens de tocht

- Pauzeer een groep voordat een route- of rosterbesluit wordt genomen.
- Gebruik support override alleen met reden; iedere actie wordt geaudit.
- Een gesloten poort wordt gecontroleerd geskipt, nooit als fictief bezoek gemarkeerd.
- Offline clients mogen alleen eerder vrijgegeven data tonen; mutaties vereisen serverbevestiging.

## Retention

`api.retention_preview` is bewust preview-only. Controleer aantallen en datum met een eventbeheerder voordat ooit een afzonderlijke verwijdermigratie wordt ontworpen. Productiedata wordt niet automatisch verwijderd door deze release.
