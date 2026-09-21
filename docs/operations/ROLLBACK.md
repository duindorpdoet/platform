# Rollbackprocedure

## Applicatie

De Sites-deployer maakt immutable releases per Git SHA/run-ID. Rol bij een appregressie terug via de bestaande Sites-release-interface naar de laatste groene SHA; force-push of `git reset --hard` is geen rollbackstrategie. Verifieer daarna `/api/health`, publieke routes en no-store op beschermde routes.

## Database

Migraties zijn forward-only en schemawijzigingen in deze release zijn additief. Draai toegepaste migraties niet blind terug: nieuwe writes kunnen anders verloren gaan. Bij een fout:

1. sluit registratie en pauzeer mailworker/operationele mutaties;
2. bepaal of een forward-fix volstaat;
3. controleer backup/PITR-beschikbaarheid en exacte impact;
4. herstel alleen na expliciete productieautorisatie en met een vastgelegd recovery point.

## Mail en Auth

- Deactiveer de job met `configure_mail_worker(..., false)` als verzending onveilig is; reeds geaccepteerde SendGrid-mail is niet terugroepbaar.
- Schakel de Auth-hook alleen uit nadat een werkend alternatief is bevestigd; anders blokkeert login.
- Wijzig of verwijder geen bestaande niet-app-specifieke SendGrid-webhooks.

## Veilige eindtoestand

Bij twijfel: applicatie naar laatste groene release, registratie `closed`, event `draft`, routeplannen niet gepubliceerd en mailworker uit. Noteer incident, SHA, tijd, betrokken migratie en herstelactie in het operationele log.
