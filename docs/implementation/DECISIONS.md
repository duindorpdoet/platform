# Technische besluiten

## Vastgelegd

| ID | Besluit | Reden |
|---|---|---|
| D-001 | De aangeleverde prototypeversie 4 is de visuele baseline. | Integriteitscontrole bevestigt commit `612b4cc4d4273c4ed9759ec53653c894229250f8`; er is geen nieuwere expliciete ontwerpbron. |
| D-002 | Next.js App Router, React en strict TypeScript worden de productieruntime. | Expliciete opdracht; de self-hosted deployment wordt hierop ingericht en Vinext-buildkoppelingen verdwijnen. |
| D-003 | `app_private` bevat operationele tabellen; `api` bevat begrensde RPC-projecties; `public` bevat alleen veilige catalogusdata. | Verkleint Data API-oppervlak en voorkomt lekkage van toekomstige routes en privéadressen. |
| D-004 | Browsermutaties gebruiken de user-JWT en databasecommands; privileged workers krijgen afzonderlijke serverauthenticatie. | Autorisatie blijft per actor/object controleerbaar; geen algemene service-key voor ouderflows. |
| D-005 | Routevoortgang is één server-side `group_run` met pessimistische rijlock, verwachte versie en idempotency receipt. | Nodig voor twee apparaten, retries en één centrale positie. |
| D-006 | De productieapp start met gesloten inschrijving en niet-gepubliceerde routeplanning. | Runconfig sluit live inschrijving uit en operationele route-invoer ontbreekt. |
| D-007 | Transactionele mail gebruikt SendGrid HTTP; OTP gebruikt een aparte Supabase Send Email Hook; appmail gebruikt een outbox. | Expliciet contract; geen Resend en geen vluchtig backgroundproces. |
| D-008 | Offline ondersteunt alleen eerder vrijgegeven leesdata; mutaties vragen serverbevestiging. | Behoudt geheimhouding en voorkomt fictieve routevoortgang. |
| D-009 | `household`, `together_party` en `walking_group` blijven afzonderlijke domeinobjecten. | Samenloop mag geen gezinsrechten geven en een organisatie-indeling is geen huishouden. |
| D-010 | Geen productieafhankelijkheid van aantallen 7, 30 of 5; zes werelden zijn configureerbare themaseed. | Demo-aantallen zijn fixtures, geen domeinconstraints. |
| D-011 | Supabase Cron triggert iedere minuut één lease-gebaseerde outboxworker; het bearer-secret staat in Vault. | Duurzame retry, één actieve schedule en geen afhankelijkheid van een browser of vluchtig proces. |
| D-012 | Staging- en productiereleases worden door afzonderlijke dedicated Sites-runners uitgevoerd. | Runnernaam, Unix-gebruiker, workspacepad, branch en exacte SHA worden voor iedere mutatie gecontroleerd. |
| D-013 | Een app-specifieke signed SendGrid Event Webhook verwerkt alleen events met een eigen opaque outbox-UUID. | Handhaaft signature/timestamp/dedupe en vermijdt PII in custom arguments. Bestaande niet-app-webhooks worden nooit aangepast. |
| D-014 | De publieke kaart valt zonder provider terug op een lokale globale wijkweergave. | Exacte poorten/routes blijven geheim en de UI doet geen valse provider- of navigatieclaim. |

## Te bevestigen in de eerste stagingrun

- Werkelijke providerrechten van de GitHub Supabase PAT en SendGrid API-key.
- SendGrid webhookcapaciteit; bij één slot mag alleen de app-specifieke staginghook naar productie worden gepromoveerd.
- Kaarttegeldienst blijft feature-geblokkeerd tot een echte stijl-URL en clientgeschikte key zijn geconfigureerd.
