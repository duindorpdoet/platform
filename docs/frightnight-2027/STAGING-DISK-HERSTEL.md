# Stagingrunner: herstel van schijfruimte

Status op 3 november 2026, 10:17 UTC: de normale release van `9b0b215f922766f6c69db67dc4f25a37d4a95c9e` stopte op `ERR_PNPM_ENOSPC` tijdens het kopiëren van dependencies. De daaropvolgende inspect-onlyjob kon zijn eigen runnerlog niet openen: `System.IO.IOException: No space left on device`. De diagnose bereikte geen `df` of `du`; het onderscheid tussen vrije bytes en vrije inodes is dus nog niet vastgesteld. Er is nog niets opgeruimd.

De bestaande health-URL antwoordde om10:12:43UTC met HTTP200 op `d8439e09c67083548d8b09ac4110d24820a52dd0`. Dit bewijst geen volledige productgezondheid bij een volle schijf. Migratie 005 is wel werkelijk toegepast. Alle vijf migraties zijn vanaf nu onveranderlijk. De behoudsvergelijking van 268 bestaande tabellen is groen; Auth, financiële historie, audit en legacy-outbox zijn behouden. Zie [concreet foutbewijs](validation/staging-9b0b215f-deploy-failure.json), [databasecontrole](validation/post005-database-metadata-9b0b215f-report.json) en [backupbewijs](validation/pre-migration-backup-9b0b215f-report.json).

## Benodigd beheerkanaal

De dedicated GitHub-runner kan op dit moment geen onderhoudsjob afronden. In deze werkomgeving is geen bruikbare SSH-identiteit, SSH-configuratie of gekoppelde VPS-shell aangetroffen. Er is daarom een bestaande operatorconsole of beschikbare, geautoriseerde SSH-route nodig. Deel geen privésleutels of wachtwoorden in chat; gebruik de bestaande veilige toegangsvoorziening.

De normale release blijft na herstel via de bestaande stagingbranch, dedicated runner, verse backup/herstelproef, behoudsvergelijking en `dg-site-deploy` verlopen. Een rechtstreeks gekopieerde app of omweg via productie vervangt die gates niet.

## Eerste controle: uitsluitend uitlezen

Voer deze controles uit in de bestaande VPS-console als Linux-gebruiker **duindorphalloweenstg**. Controleer eerst de identiteit; stop bij een andere gebruiker. De commando's wijzigen geen bestanden.

```bash
id -un
df -h -- /srv/sites/duindorphalloweenstg
df -i -- /srv/sites/duindorphalloweenstg
readlink -f -- /srv/sites/duindorphalloweenstg/actions-runner/_work/platform/platform
du -xsh -- /srv/sites/duindorphalloweenstg/actions-runner/_work/platform/platform/.next/cache
du -xsh -- /srv/sites/duindorphalloweenstg/actions-runner/_work/platform/platform/node_modules/.cache
```

Een ontbrekende cache is geen reden een bredere map te verwijderen. Leg vrije bytes/inodes, cacheomvang, werkmappad en de actuele releasekoppeling vast zonder envbestanden of private logs uit te lezen. Controleer vóór onderhoud dat geen stagingbuild loopt.

## Beperkte herstelkeuze na de controle

De bestaande onderhoudscode [staging-runner-maintenance.mjs](../../scripts/deploy/staging-runner-maintenance.mjs) kent twee herbouwbare caches: `.next/cache` en `node_modules/.cache` in exact die stagingwerkmap. Hij controleert actuele gebruiker, runner, werkmap en symlinkgrenzen. Het doel van een herstelactie is voldoende ruimte om de normale runner weer te laten starten; daarna kan de bestaande `clear-build-cache`-route worden gebruikt. Een operatoractie buiten de runner moet dezelfde echte gebruiker, pad- en symlinkgrenzen controleren; vervals daarvoor geen GitHub-runnercontext.

Verwijder geen volledige `node_modules`, releases, backups, gebruikersgegevens, productiecache of databases als ongecontroleerde uitbreiding. Het nog onvoltooide releasepad `releases/9b0b215f9227-41615887268-1` is geen gepubliceerde release, maar is tot nu toe ook niet verwijderd. Een eventuele gerichte opruiming ervan vraagt eerst bewijs van eigenaar, pad, afwezigheid van actieve verwijzingen en concreet gemeten omvang. Bewaar de bestaande herstelreleases en versleutelde backups.

De bestaande workflowoptie `recover-shared-disk` gebruikt een productiegebruiker. Die optie hoort niet bij deze stagingopdracht en is niet uitgevoerd.

## Hervatten na herstel

1. Bevestig voldoende vrije bytes én inodes en een weer startende dedicated stagingrunner.
2. Start een nieuwe normale stagingrelease op exact `9b0b215f922766f6c69db67dc4f25a37d4a95c9e`, met `runner_maintenance=none`, `skip_mail_tests=false` en `skip_mail_acceptance=false`. De vereiste exacte CI41612954081 is volledig groen. Gebruik geen gedeeltelijke deployretry die de verse backup/herstel-/behoudsgates weglaat.
3. De vijf migraties zijn al toegepast; de nieuwe historiecontrole moet dit bewijzen zonder bronwijziging of lege migraties. Initialisatie blijft idempotent.
4. Controleer werkelijk gepubliceerde SHA, immutable pad, health, private grenzen en volledige account-/Storage-/REG-/EDGEacceptatie. Voer pas daarna de begrensde 125-clientbelasting en verse 32-tabel-RET05-scenariorestore uit.
5. Start na alle writes en cleanup het definitieve read-only observatievenster: twee nieuwe natuurlijke geslaagde cycli van elk legacyjob 45/81/184 en gelijke inhoud/counts van alle 32 FrightNight-tabellen en legacy-outbox. Geen handmatige jobaanroep of globale uitschakeling.

Zolang de nieuwe publicatie en deze proeven niet werkelijk geslaagd zijn, blijft de productoverdracht onvolledig. De oude d843-app is geen volledig geaccepteerd005-rollbackpunt; zie [compatibiliteit](POSTGREST-COMPATIBILITY.md).
