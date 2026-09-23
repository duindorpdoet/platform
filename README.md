# De Duindorpse Poorten van Halloween

Productieplatform voor de Halloween-avondloop in Duindorp op 31 oktober 2026. De applicatie gebruikt Next.js App Router, strict TypeScript, Supabase Auth/Postgres/Realtime/Storage/Cron en SendGrid. De aangeleverde ontwerpversie 4 blijft de visuele basis; productie bevat geen rollenknop, universele democode of fictieve deelnemers.

## Lokaal ontwikkelen

Vereisten: Node.js 24, pnpm 11.25, Docker en de in `package.json` vastgezette Supabase CLI.

```bash
pnpm install --frozen-lockfile
cp .env.example .env.local
pnpm exec supabase start
pnpm exec supabase db reset
pnpm dev
```

De lokale seed bevat uitsluitend technische fixtures en wordt nooit naar staging of productie gepusht. De Data API exposeert alleen schema `api`; operationele tabellen staan in `app_private` en zijn niet direct browserbereikbaar.

## Verificatie

```bash
pnpm verify
pnpm test:e2e
pnpm exec supabase db reset
pnpm exec supabase test db
pnpm exec supabase db lint --level warning
```

De testset omvat domein-unit-tests, browseracceptatie op desktop en mobiel, een volledig herbouwde lokale database, 338 pgTAP-contracttests en schemalint. De stagingworkflow voegt echte OTP-, mailbox-, SendGrid-webhook- en deploymenttests toe.

De lokale integratie- en browsertests wijzigen testfixtures. Voer pgTAP na een database-reset uit en reset opnieuw vóór de aangemelde browsertests. De CI-workflow bevat de volledige volgorde en lokale omgevingsvariabelen. De 200-clientproef draait uitsluitend tegen localhost:

```bash
pnpm exec supabase db reset --local
eval "$(pnpm exec supabase status -o env)"
SUPABASE_URL="$API_URL" SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" node scripts/acceptance/load.mjs
```

Deze proef gebruikt één bevoegde testidentiteit en meet 600 snapshotrequests plus 200 gelijktijdige, identieke afrondingsverzoeken. Dit is lokaal regressiebewijs; productiecapaciteit en de echte telefoon-/netwerkproef vereisen aparte metingen.

## Releaseflow

- `main`: geïntegreerde, lokaal en in CI geverifieerde code.
- `staging`: exact te accepteren release; deployment naar `https://staging-halloween.duindorpdoet.nl`.
- `production`: uitsluitend dezelfde commit die als succesvolle stagingdeployment is geregistreerd; deployment naar `https://halloween.duindorpdoet.nl`.

De stagingworkflow opent alleen de testregistratie en beperkt transactionele mail tot de twee geautoriseerde testmailboxen. Aangevraagde inlogcodes worden ook op staging naar het eigen e-mailadres verstuurd. Productie blijft via zowel runtimeconfig als databasecontrol `closed`/`draft`; echte routeplannen worden alleen door een bevoegde beheerder gepubliceerd. De productie-mailmodus wordt pas bereikt na de exacte-staging-commitgate.

Zie [RUNBOOK.md](docs/operations/RUNBOOK.md), [ROLLBACK.md](docs/operations/ROLLBACK.md), [STATUS.md](docs/implementation/STATUS.md) en [ACCEPTANCE.md](docs/implementation/ACCEPTANCE.md).
