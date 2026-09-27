# De Poortkamer V1 — implementatie en controle

Bron: de aangeleverde Codex-implementatieprompt, uitgevoerd vanaf staging `9f2362f`.
De afzonderlijke beeldprompts zijn assetbeschrijvingen; de zeven aangeleverde WebP's worden gebruikt.

## Architectuurkeuzes

- `/mijn-huis` blijft de ingang. Aanmelding en beoordeling blijven in de bestaande wizard; goedgekeurde leden krijgen De Poortkamer.
- `portal_owners` blijft de enige membershipbron. Rollen en één primaire eigenaar worden daarin vastgelegd. Portaalrijlocks en een uitgestelde constraint bewaken overdracht.
- Bezoeken komen uit bestaande reserveringen, routeplannen, run-stops en scanbewijzen. Geen tweede planner. Pauze/stop roept het bestaande operationele contract aan.
- Privékanalen bevatten uitsluitend identifiers. Snapshot/read-RPC's controleren toegang iedere keer opnieuw. Presence is alleen een aanwezigheidsindicatie, nooit autorisatie.
- Bestaande Supabase e-mail-OTP, premium mailcatalogus, outbox, cron en pushabonnementen blijven leidend. Uitnodigingen bewaren alleen een tokenhash; een sleutel in Vault maakt alleen voor de mailworker de link reproduceerbaar.
- Chat is een aparte resource met begrensde historie en leesstatus, geen tweede supportmessenger. Hulp aan de organisatie gebruikt de bestaande supportflow.
- Geen permanente offline opslag van Poortkamerdata. Een gemarkeerde, tijdelijke weergave in het geheugen verdwijnt bij accountwisseling/uitloggen.
- De repository heeft geen onafhankelijke goedgekeurde acteursregistratie. Goedgekeurde crew/acteurs krijgen toegang via hun actieve poortmembership; een clientlabel geeft nooit toegang.

## Werkchecklist

- [x] Memberships, primary constraint, uitnodigingen, oude schrijfrechten.
- [x] Snapshot, bevestigde bezoeken, voorraad, checklist, getimede pauze, Nachtverslag.
- [x] Privéchat, community, Omroeper, moderatie, leesstatus, retentie.
- [x] Realtime, pushvoorkeuren en duurzame meldingen via bestaande worker.
- [x] Premium responsive interface, teambeheer en uitnodigings-OTP.
- [x] Admininformatie en moderatie.
- [x] pgTAP, concurrency, browserflows, toegankelijkheid, offline en verify.
Releasevolgorde: eerst de volledige PR-CI, daarna staging inclusief mailacceptatie, daarna productie. De PR bevat de definitieve workflowlinks en release-revisie.

## Realtime bij intrekking

Realtime berekent autorisatie bij toetreden. Daarom hebben Poortkamer en Poortplein een membership-generatie in hun topic. Een wijziging in rechten verstuurt één identifier-only invalidatie naar het oude topic; volgende berichten gebruiken een nieuwe generatie. Iedere RPC controleert de actieve membership opnieuw. Een oude WebSocket ontvangt dus geen nieuwe chatdata of nieuwe aanwezigheidsupdates. De publieke/legacy `portal:`-signalen blijven beperkte identifiers voor bestaande functionaliteit.

Bronnen: [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization), [Presence](https://supabase.com/docs/guides/realtime/presence).
