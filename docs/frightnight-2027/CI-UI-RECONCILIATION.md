# CI-controle bij de vervanging door FrightNight v7

De stagingapp gebruikt nu zelfstandige Nachtpassen, vrijwillige samenloop en Mijn zone. De oude Poortenboek-/Poortkamer-/Startregieschermen zijn vervangen. Hun oude browserselectors zijn geen acceptatiecontract voor het nieuwe product.

De applicatiejob draait voortaan `playwright.frightnight.config.ts`: de actuele publieke website, minder beweging, toetsenbord, inlogformulier, vier beveiligde omgevingsingangen, private-APIweigering, mobiel, PWA en vooraf beschikbare noodinformatie. De gepubliceerde stagingrelease krijgt daarnaast echte, synthetische Auth-/gezinnen-/bewoner-/regie-/routeacceptatie in een afzonderlijke 2027-testeditie; zonder OTP, externe mail of bestaande huishoudens.

Behouden: `pnpm verify`, alle bestaande pgTAP-/domein-/server-/securitytests, databasehistorie, schema-lint, backupfingerprints, mailhistoriebehoud, bounded-readbenchmarks, echte lokale Auth, 200-clientproef en alle bestaande SQL/HTTP-concurrentiescripts. Alleen verouderde browserstappen zijn vervangen; gemengde stappen behouden hun niet-UI-scripts. Productiedeploygates blijven ongewijzigd.

De vijf losse UI-configs in de applicatiejob (Poortenboek-refresh, event-evening, event-thanks, portal-impact, portal-certificate-mail) zijn door de actuele FrightNight-browserconfig vervangen. De volgende verouderde browseraanroepen zijn uit de databasejob vervangen; hun database-/domeinregels blijven in de behouden tests gecontroleerd:

- `pnpm exec playwright test --config playwright.poortkamer-thanks-closed.config.ts`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/start-ops.spec.ts tests/e2e/start-location.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/portal-sequence.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/group-operations.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/finale-target.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/start-readiness-time.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/released-destination.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/registration-management.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/registration-management.spec.ts --project=mobile-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/joint-route-planboard.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/joint-route-planboard.spec.ts --project=mobile-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/authenticated-live.spec.ts tests/e2e/homeowner-responsive.spec.ts tests/e2e/participant-mobile-polish.spec.ts tests/e2e/together-management.spec.ts tests/e2e/contact-identity.spec.ts --project=desktop-chromium --workers=1`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test tests/e2e/together-management.spec.ts tests/e2e/contact-identity.spec.ts --project=mobile-chromium`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_SECRET_KEY="$SECRET_KEY" pnpm exec playwright test --config playwright.realtime.config.ts`
- `NEXT_PUBLIC_SUPABASE_URL="$API_URL" NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" pnpm exec playwright test tests/e2e/pwa-attendance.spec.ts --project=mobile-chromium --workers=1`
- `pnpm exec playwright test --config playwright.poortenboek.config.ts`
- `pnpm exec playwright test --config playwright.ops-chain.config.ts`
- `pnpm exec playwright test --config playwright.poortkamer.config.ts`
- `pnpm exec playwright test --config playwright.planboard.config.ts`
- `pnpm exec playwright test --config playwright.account-app.config.ts`
- `pnpm exec playwright test --config playwright.guidance.config.ts`
- `pnpm exec playwright test --config playwright.portal-qr.config.ts --project=qr-desktop`
- `pnpm exec playwright test --config playwright.portal-qr.config.ts --project=qr-mobile`
- `pnpm exec playwright test --config playwright.editorial.config.ts`
