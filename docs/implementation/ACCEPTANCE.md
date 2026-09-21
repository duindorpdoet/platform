# Acceptatiebewijs

Statuswaarden: `pass`, `fail`, `blocked`, `not-run`. Alleen daadwerkelijk uitgevoerd bewijs krijgt `pass`. De volledige 143-regelige bronmatrix staat in `acceptance-matrix.csv`; implementatie alleen is geen testbewijs.

## Lokaal checkpoint

| Gebied | Status | Bewijs |
|---|---|---|
| Bronintegriteit en ontwerpport | pass | Meegeleverde packageverifier: 170 bestanden; versie 4. Playwright desktop/mobiel controleert merk, routes en afwezigheid van demoauth. |
| Applicatiekwaliteit | pass | `pnpm lint`, `pnpm typecheck`, 42 Vitest-tests en `pnpm build`. |
| Browserbasismatrix | pass | 18 Playwright-tests: desktop + Pixel 7, publieke routes, OTP-UI, redirects, headers, PWA, motion en kaartprivacy. |
| Databasebasis | pass | Zeven migraties vanaf nul; 218 pgTAP-tests; `supabase db lint --level warning` zonder bevindingen. |
| Provideracceptatie | blocked | Stagingrun `35643888861`: beide toegestane ontvangers hebben een bestaande SendGrid `block`-suppression; bestaande gedeelde resources mogen niet worden gewijzigd. |
| Remote security advisors | pass | Stagingrun `35643888861`: Supabase security-advisors en gedeployde HTTP-smoke voor `c66798c` waren groen vóór de bekende mailgate. |
| Echte route-/avondproef | blocked | Operationele data en fysieke iOS/Android-avondproef ontbreken. |
| Productie | not-run | Alleen toegestaan na succesvolle stagingdeployment van exact dezelfde commit. |

## Bewijsconventies

- `local:db-001..014` verwijst naar de pgTAP-bestanden in `supabase/tests`.
- `local:unit` verwijst naar de Vitest-domeintests in `lib/domain` en `lib/mail`.
- `local:e2e` verwijst naar `tests/e2e` op beide Playwright-projecten.
- `workflow:staging` en `workflow:production` zijn pas bewijs nadat de betreffende GitHub deployment groen is.
- `blocked:operations` betekent dat echte organisatie-invoer of fysieke hardware nodig is, niet dat de technische implementatie als geslaagd geldt.
