# Werkelijke HTTP-regressie tegen PostgREST 14.5

De [officiële Supabase-uitleg](https://supabase.com/kb/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions) beschrijft dat PostgREST 14 zakelijke `40001`-exceptions automatisch opnieuw probeert; PostgREST 16 heeft dit probleem niet. De bestaande lokale 16.2-proef kon daardoor de gepubliceerde 14.5-afwijking niet reproduceren.

`native-before-after-report.json` is daadwerkelijk op 3 november 2026, 09:30 UTC uitgevoerd met de officiële container `public.ecr.aws/supabase/postgrest:v14.5`, digest `sha256:b574528fe109c8343c1247155734d03df8c34b462f342dca0ccc20244fc36ef9`. De container luisterde uitsluitend op loopback 63564 en gebruikte een nieuwe wegwerpclone van de lokale QA-database. De gedeelde gateway, productie, staging en de oorspronkelijke QA-databasefuncties zijn niet aangepast.

De proef gebruikte twee nieuwe eigen `.invalid` GoTrue-accounts, een nieuwe private editie en een bevestigd synthetisch huis. Een echte succesvolle beoordeling verhoogde versie 3 naar 4. Daarna stuurde de harness één native HTTP-aanvraag naar de bestaande RPC `frightnight_command` met een goedkeuring op de oude versie 3.

| Uitvoering | Werkelijke HTTP-uitkomst | Transactiepogingen binnen één HTTP-verzoek | Huis na het verzoek |
| --- | --- | --- | --- |
| Vóór migratie 005 | 499 `PT499` / `LOCAL_RETRY_LIMIT` door uitsluitend de lokale veiligheidsbegrenzer | 6 | Versie 4, wijziging gevraagd, reden behouden |
| Na exact migratie 005 | 409 `PT409` / `VERSION_CONFLICT` | 1 | Dezelfde versie, status en reden behouden |
| Daarna goedkeuring met actuele versie 4 | 200 | Normale aanvraag | Versie 5, goedgekeurd |

De veiligheidsbegrenzer stond uitsluitend in de nieuwe clone: een niet-transactionele sequence telde aanvangspogingen in een pre-request-hook, geactiveerd door een header met de exacte onvoorspelbare run. De zesde poging stopte een anders onbegrensde lokale retry. De eerste vijf pogingen voerden de ongewijzigde zakelijke RPC uit. De bedrijfsfuncties werden pas daarna met de exacte additieve migratie 005 bijgewerkt. Er is geen `001`–`004`-bron herschreven.

De eigen container, databaseclone en geheime envfile zijn verwijderd. Beide nieuwe Auth-records zijn behouden en uitsluitend deze eigen accounts zijn buiten gebruik gesteld na baseline-/metadatahercontrole. Bestaande QA-personas zijn niet gebruikt of gewijzigd. Er waren geen OTP-, externe PSP-, mail- of pushtests.

`native-before-after-harness.mjs.txt` is bytegelijk aan het daadwerkelijk uitgevoerde script; de oorspronkelijke bestandsnaam en SHA staan in `helper-versions.json`. Er zijn geen sleutels, passwords of sessies in dit dossier opgenomen.

## Aanvullende controle en beperkingen

De zeven permanente unit-/handlerregressies in `lib/frightnight/server-rpc-error.test.ts` zijn geslaagd. Ze behouden de gecontroleerde Nederlandse versieconflictmelding, geven onbekende PT409-fouten veilig als constante HTTP 409 door en voorkomen dat SQL- of `FN_*`-details lekken. De echte commandhandler roept de RPC één keer aan en retourneert private/no-store. De twee betreffende appbestanden zijn vastgelegd in commit `9b0b215f`.

Een aanvullende native controle met echte gelijktijdige updates in SERIALIZABLE-isolatie bereikte de lokale limiet van zes pogingen, met zestig gecommitte updates en zonder Auth-acties. De strikte controle eiste tevens vijf specifieke database-logregels; deze ontbraken in de gebruikte Docker-logroute. Daarom blijft `engine-control-report.json` **failed/onbewezen** en telt dit niet als geslaagde native engine-40001-controle. Het aparte backend-SQL-bewijs bepaalt die dekking. De bijbehorende tijdelijke RPC gebruikte de exacte classifier en wijzigde geen productie-RPC-definitie.

De eerdere setupfouten zijn transparant bewaard: verlopen raw JWT vóór fixtureopbouw; een tijdelijke SQL-dollarquoteconstructiefout; en een lokale GoTrue 504/contextdeadline bij een aanvullende accountsetup. De laatste cleanup-read liep ook af. `engine-auth-timeout-cleanup-followup.json` bewijst het later afgeronde buiten gebruik stellen van uitsluitend het exacte nieuw aangemaakte account na herbevestiging van run, metadata, `.invalid`-prefix en creatievenster. Er is geen blinde signOut-retry of generieke Auth-opschoning uitgevoerd.

Deze lokale diagnose is geen nieuwe hosted acceptatie en vervangt de verplichte nieuwe CI-/releasegates niet.
