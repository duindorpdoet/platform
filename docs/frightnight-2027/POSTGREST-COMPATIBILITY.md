# Domeinconflicten en PostgREST 14

De gepubliceerde staging gebruikt PostgREST 14.5. De lokale QA-gateway gebruikte 16.2. Daarom bewezen geslaagde lokale HTTP-proeven niet het managed gedrag bij een bewust opgewekte SQLSTATE `40001`. Supabase documenteert dat PostgREST 14 zo’n fout onbeperkt opnieuw kan proberen; versie 16 verhelpt dit. Voor bedoelde businessconflicten adviseert Supabase een standaardexception of een expliciete HTTP-code zoals `PT409`. [Officiële kennisbank](https://supabase.com/kb/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions).

De eerste HUI02-proef op `d8439e09` wijzigde de beoordeling eenmaal naar versie 4. Er is geen goedkeuring gecommit. Het geschoonde logvenster 09:14:40–09:15:03 UTC bevat negentien daadwerkelijke `VERSION_CONFLICT`-fouten met SQLSTATE `40001` vanuit dezelfde RPC-stack en backend-PID 1361450, ongeveer iedere seconde. De laatste fout van die PID is `42501` om 09:15:00.149. De parent bewaarde de uiteindelijke HTTP-status niet; een deadline-/503-respons blijft daarom een inferentie totdat de versie-14.5-reproductie die bevestigt. [Logbewijs en versiemetadata](validation/postgrest-14-conflict-diagnosis/managed-log-report.json).

Om 09:25:50 UTC bestond deze PID niet meer en waren er nul actieve oude of actuele FrightNight-calls via `authenticator`. Hiervoor zijn geen sessies beëindigd, cronjobs gestopt of projecten herstart. De extra ongewijzigde run `41610352325` is vóór deploy en parent gestopt; zijn backupjob is geannuleerd en er is geen backupartifact ontstaan. De eerdere geslaagde backup en veilige fixturecleanup blijven afzonderlijk vastgelegd.

## Contract van migratie 005

`20261103092502_frightnight_2027_domain_conflicts.sql` voegt uitsluitend een transportgrens rond zeven bestaande FrightNight-RPC’s toe. De vier eerder toegepaste migraties blijven bytegelijk. De transportlaag vertaalt alleen SQLSTATE `40001` met een van zestien exact bekende businessmeldingen naar `PT409`. Onbekende meldingen en echte database-serialisatiefouten behouden hun oorspronkelijke fout. De app zet `PT409` om naar een begrijpelijke HTTP409-conflictrespons. Afwijzing en transactierollback blijven verplicht; de testverwachting 409 wordt niet versoepeld.

| RPC | Bestaande bevoegdheidsgrens |
| --- | --- |
| `frightnight_command` | Geauthenticeerde actor met actuele editie-/commandbevoegdheid |
| `frightnight_contract_arm` | Service-only; actuele actor, testbeheer en exacte lege private run |
| `frightnight_payment_claim` | Service-only; actuele actor/registratie en vertrouwde providerclaim |
| `frightnight_payment_test_claim` | Service-only; actuele testbevoegdheid en contractorder |
| `frightnight_payment_bind` | Service-only; onveranderlijke order-/providerbinding |
| `frightnight_payment_for_refund` | Service-only; actuele financiële bevoegdheid vóór een nieuwe refundclaim |
| `frightnight_payment_refund_record` | Service-only; exacte vooraf geautoriseerde claim en providerbinding, ook na latere rolintrekking |

De bestaande implementaties blijven achter expliciet ingetrokken private EXECUTE-rechten staan. Signaturen, veilige `search_path`, actor-/editiecontroles, minimale receipts en financiële idempotentie blijven behouden. De veiligheidscontrole blijft exact 32 tabellen en vier voor Auth toegestane API-RPC’s vereisen. Nieuwe private functies krijgen geen clienttoegang. Confirmatie van echte providerontvangst wordt niet afhankelijk gemaakt van een latere actorban of sandboxreset.

## Controle en herstel

Lees bij herhaalde conflicten eerst een begrensd logvenster. Verzamel alleen tijd, SQLSTATE, functiepad en backend-PID; geen volledige query, payload, token, IP of persoonsgegevens. Koppel de log-PID aan actuele `pg_stat_activity`-metadata en controleer begintijd en functiescope opnieuw wegens PID-hergebruik. Een browserdeadline is geen bewijs dat een database-retrylus gestopt is. Als de PID al verdwenen is en er geen oude actieve FrightNight-calls meer zijn, is geen beëindiging nodig.

Een nog actieve bewezen eigen foutlus vraagt gerichte operationele beoordeling. Verwijder geen data, verruim geen grants en stop geen algemene cron of database als vervanging voor die diagnose. Financiële ontvangst, bestaande claims en audit blijven behouden. De kennisbankprocedure voor beëindiging mag uitsluitend op een opnieuw geverifieerde bijbehorende backend worden toegepast binnen de geldende operationele bevoegdheid.

De correctie vereist een nieuwe exacte groene CI, een verse normale stagingbackup/herstelproef met de exacte 005-bron, onverkorte vergelijking van bestaande gegevens en een normale stagingrelease. Daarna blijven de daadwerkelijke HUI02-409-proef, private Storage-HTTP-proeven, REG/EDGE, belasting tot 125, scenarioherstel en twee natuurlijke legacyjobcycli verplicht. De actuele uitvoering staat in `IMPLEMENTATION-STATUS.md`; dit document claimt die nog niet als geslaagd. Een PostgREST-upgrade of productieaanpassing hoort niet bij deze correctie.

Na toepassing blijft ook migratie 005 onveranderlijk. Een volledige compatibele app moet zowel de opgeslagen providerclaims uit 003 als de gecontroleerde `PT409`-mapping ondersteunen. De oudere `d8439e09`-/`5ccf0981`-apps herkennen sommige bekende conflictteksten al, maar missen de generieke veilige mapping voor de overige zakelijke `PT409`-fouten; zij vormen daarom geen volledig geaccepteerd rollbackpunt voor deze nieuwe transportlaag. Herstel verwijdert de nieuwe wrappers niet en zet geen gereserveerde `40001`-businesscodes terug. Het concrete nieuwe rollbackpad wordt pas na de volledige gepubliceerde acceptatie vastgelegd; tot die tijd gelden editiepause, vooraf beschikbaar operationeel noodpakket en een gecontroleerde compatibele forwardfix, met behoud van alle financiële, Auth- en audithistorie.
