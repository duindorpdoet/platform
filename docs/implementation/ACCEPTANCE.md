# Acceptatiebewijs

Statuswaarden: `pass`, `fail`, `blocked`, `not-run`. Alleen daadwerkelijk uitgevoerd bewijs krijgt `pass`. De volledige 143-regelige bronmatrix staat in `acceptance-matrix.csv`; implementatie alleen is geen testbewijs.

## Checkpoint — bijgewerkt op 22 september 2026

Applicatie-, browser-, database-, lokale Auth-, samenloop- en bundelchecks zijn opnieuw uitgevoerd op 22 september. Bronpakket- en remote workflowbewijs hieronder komt uit het eerdere checkpoint.

| Gebied | Status | Bewijs |
|---|---|---|
| Bronintegriteit en ontwerpport | pass | Meegeleverde packageverifier: 170 bestanden; versie 4. Playwright desktop/mobiel controleert merk, routes en afwezigheid van demoauth. |
| Applicatiekwaliteit | pass | `pnpm lint`, `pnpm typecheck`, 50 Vitest-tests en `pnpm build`. |
| Browserbasismatrix | pass | 24 Playwright-tests: desktop + Pixel 7, publieke routes, OTP-UI, redirects, headers, PWA, motion en kaartprivacy. |
| Aangemelde browseracceptatie | pass | Vijf desktoptests tegen lokale Supabase: vervalste sessie/offline/reconnect, meerkindregistratie en wijzigingsverzoek, poortconcept en uploadgrens; smalle schermen en 200 procent tekst voor private rollen en beheeronderdelen. De tien aangemelde varianten worden zonder lokale configuratie in de publieke suite overgeslagen. |
| Databasebasis | pass | Negen migraties vanaf nul; 338 pgTAP-tests; `supabase db lint --level warning` zonder bevindingen. |
| Lokale Auth en samenloop | pass | `local-auth.mjs`: acht Auth/mailcriteria; `concurrency.mjs`: acht registratie-/planning-/racecriteria met parallelle transacties. |
| Nieuwe regressies | pass | Cameratracks stoppen ook bij late toestemming en navigatie; echte SW-update bewaart onopgeslagen invoer; wizard focust fouten/stappen en verstuurt niets na saveconflict. |
| Lokale 200-clientproef | pass | `load-acceptance-20260922.json`: 800 requests zonder fouten; p95 snapshots 305–430 ms en afronden 434 ms; één testidentiteit; één routeadvance. Geen productiecapaciteitsclaim. |
| Handmatige toegankelijkheid | not-run | Automatische smalle-scherm-/200-procent-tekstchecks en basistoetsenbordbediening slagen; volledige handmatige UX-03-controle blijft open. |
| Browserbundels | pass | `pnpm test:artifacts`: 587 productiebestanden gescand. |
| Provideracceptatie | blocked | Stagingrun `35700649499` stopte door onjuiste classificatie van historische blocks als permanente suppressions. Check gecorrigeerd; echte bezorging opnieuw te verifiëren (B-005). |
| Remote security advisors | pass | Stagingrun `35643888861`: Supabase security-advisors en gedeployde HTTP-smoke voor `c66798c` waren groen vóór de bekende mailgate. |
| Echte route-/avondproef | blocked | Operationele data en fysieke iOS/Android-avondproef ontbreken. |
| Productie | not-run | Alleen toegestaan na succesvolle stagingdeployment van exact dezelfde commit. |

## Bewijsconventies

- `local:db-001..019` verwijst naar de pgTAP-bestanden in `supabase/tests`.
- `local:unit` verwijst naar de Vitest-domeintests in `lib/domain` en `lib/mail`.
- `local:e2e` verwijst naar `tests/e2e` op beide Playwright-projecten.
- `workflow:staging` en `workflow:production` zijn pas bewijs nadat de betreffende GitHub deployment groen is.
- `blocked:operations` betekent dat echte organisatie-invoer of fysieke hardware nodig is, niet dat de technische implementatie als geslaagd geldt.
