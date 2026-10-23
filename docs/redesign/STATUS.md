# Redesign: implementatie aanwezig, acceptatie nog open

Stand: 23 oktober 2026. **Niet gereed voor uitrol.** Er is geen nieuwe stagingdeployment of productiedeployment uitgevoerd. De volledige opdracht is pas voltooid nadat de hieronder genoemde bewijzen beschikbaar zijn.

## Bron en basis

De 468 SHA256-vermeldingen uit de overdracht zijn gecontroleerd. Presentatie komt uit prototypecommit `0a0d2edc6b371859ba014c2c279a91759f3e9112`; herkomst staat in [source-provenance.json](source-provenance.json). De geïsoleerde werkboom is gestart vanaf `bc2b3796d39f79f7f6dc5ef5bd4978a304eb125b`. Deze SHA is bij aanvang bevestigd via de health-endpoints en GitHub-deploymentgegevens van staging en productie. Oude main en bestaande werkbomen zijn niet als implementatiebasis gebruikt of overschreven.

De nieuwe componenten gebruiken Next-routes, bestaande Supabase-authenticatie en geautoriseerde RPC's. De prototype-interceptor, hash-router, fictieve accounts, scenario-reset en Sites-hostingconfiguratie zijn niet aangesloten. De bestaande demonstratiefunctie van het productieplatform is niet gebruikt als bewijs voor echte deelnemers.

## Wat in de code staat

| Onderdeel | Overname en aansluiting | Nog te bewijzen |
| --- | --- | --- |
| Publieke website | Broncomponenten, 18 moderne CSS-lagen in de oorspronkelijke cascade, originele beelden, wereldpagina's en mobiele navigatie; bestaande contentmodules behouden | Volledige beeldvergelijking, CMS-inhoud en formulieren op staging |
| Ouders/deelnemers/meekijkers | Persoonlijke shell, echte routes, bestaande modules en rechten; actuele bestemming en aankomstvoorstel | Alle rollen en privégrenzen in ingelogde browsers |
| Poortkamer | Bronpresentatie; Nachtwacht, bezoeken, team, berichten, Meer; QR/print en eigen bedankjes aangesloten | Poortrollen, dialogen, realtime en mobiele bediening op staging |
| Nachtregie | Nieuwe menugroepen en capabilityfilters rond bestaande beheermodules; Generale en Bedankjes | Alle capabilities, modules en belangrijke dialogen vergelijken |
| Aankomst/QR | Servervalidatie, atomair aankomen/afronden, code-only variant, idempotente ontvangstbewijzen, geldigheid oude hashes behouden | Nieuwe versleutelde posters end-to-end, echte parallelle telefoons, camera en papier |
| Inclusieve zegels | Aanwezigheid als afzonderlijk historisch feit; `all_skipped` blijft bestaan; finale werkt met bevestigde aankomst; geen zegel bij systeemoverslag | Representatieve historische backfill en staging |
| Dagmelding/rondleidingen | Amsterdamse account/event/dagbevestiging op server; afzonderlijke 14-stappenrollen, 9-stappenkindertour, servervoortgang en globale volwassen montage | QR-intentie door login/tours heen, focus/keyboard en alle loginbestemmingen |
| Kinderpoortenboek | Identiteitscontrole bij wissel, vier SVG-lantaarns/zes kleuren, zes servermatig vrijgegeven verhalen, lezen en optioneel voorlezen | Kindwissel, audio, apparaatbeperkingen en sessies in echte browsers |
| Bewaarkaart | Persoonlijke downloadbare A4-PDF; echte eigen zegels; nul zegels en paginering | Browserdownload op iOS/Android en fysieke afdruk |
| Synchronisatie | Versleutelde IndexedDB-opdrachten met vaste sleutel; account/event/groepafbakening, herstel en vier zichtbare statussen | Echte browserreload, logout, volle opslag en netwerkverlies rond servercommit |
| Vroeg vertrek | Huishoudautorisatie, selectie eigen kinderen, behoud andere gezinnen, leiderschapsoverdracht en warme eigen afsluiting | Complete bediening en gelijktijdige routeacties op staging |
| Bedankjes | Unieke event/huishouden/poortconstraint; alleen eigen bevestigde aankomsten; geanonimiseerde poort-/organisatiebeelden | Alle rollen en verversing op staging |
| Generale | 12 scenario's/46 meetpunten tegen echte SQL-domeincommando's met teruggedraaide, geïsoleerde fixtures | Echte Supabase/API-browserketen; geen bewijs voor hardware |

## Uitgevoerde lokale controles

Zie [validation/results.json](validation/results.json) voor de geteste applicatie-SHA en commando's.

- Lint, TypeScript, 269 unitcontroles in 45 bestanden, Next-productiebouw en clientartifactcontrole geslaagd; 1.035 buildbestanden gescand.
- 62 SQL-testbestanden met 1.652 pgTAP-controles geslaagd op afzonderlijke PostgreSQL 16 met synthetische fixtures. Inclusief 113 nieuwe controles, 12/46 Generale en ongewijzigde vingerafdrukken van alle private rijen na Generale.
- Auth-, Storage-, Realtime-, Cron- en HTTP-servicegrenzen van deze lokale database zijn stubs. Dit is echte PostgreSQL-domeinlogica, **geen bewijs van werkende Supabase-services of staging**.
- Vier nieuwe migraties opnieuw toegepast op die synthetische database. Voor/na: 142 tabellen vergeleken, nul gewijzigde bestaande datavingerafdrukken. Dit bewijst herhaalbaarheid in die fixture, niet behoud van echte productiegegevens of herstelbaarheid van een productiebackup.
- Vijftig bestaande publieke browsercontroles geslaagd op desktop en mobiel, inclusief 200% tekstzoom, toetsenbord en securityheaders. Deelstudio gebruikt in die UI-test geïntercepteerde antwoorden; dat is geen backendbewijs.
- Twintig publieke screenshots op desktop, tablet en 360/390/430 px; geen gemeten horizontale overflow. Zes PDF's gerenderd: 0/2/5/40 zegels en mono/kleurposter. Langste kaart: zeven pagina's.

Elke regel van de 66 acceptatiegevallen staat in [acceptance.csv](acceptance.csv). Lokale deelbewijzen zijn afzonderlijk vermeld; geen regel is als volledig op staging geaccepteerd afgetekend.

## Blokkerende ontbrekende bewijzen

1. De gekoppelde Supabase-account toont niet de echte Halloween-projecten. Bevoorrechte projecttoegang bestaat in de bestaande GitHub Actions-omgevingen, maar is hier niet beschikbaar. De daadwerkelijk toegepaste migratiestand, RLS, storage, flags, nulmeting en historische uitzonderingen zijn daarom niet live geïnventariseerd.
2. Er is geen consistente versleutelde productiebackup gemaakt of naar een geïsoleerde omgeving hersteld. Geen productie- of stagingmigraties zijn gestart. Gebruik [UITROL.md](UITROL.md) voordat de branch naar staging gaat; de bestaande stagingworkflow migreert automatisch na een merge.
3. Er is geen nieuwe exact geteste staging-SHA. Alle 66 gevallen moeten op echte stagingservices worden doorlopen, inclusief echte gelijktijdigheid, OTP/sessies en netwerkherstel.
4. Pixelperfecte gelijkheid is niet aangetoond. Publieke geometrie is deels gemeten; fontmetriek wijkt af. Voor ingelogde omgevingen en belangrijke dialogen ontbreken passende captures. Zie [VISUEEL.md](VISUEEL.md).
5. Fysieke zwart-witafdruk, telefoon/camera, mobiel bereik, iOS/PWA en volledige toegankelijkheidscontrole staan open.

Geen live data is voor dit werk gereset, geseed, geroteerd of gemigreerd. Dat is geen garantie dat een toekomstige migratie gegevensverlies onmogelijk maakt: de nulmeting, hersteltest en vergelijking blijven vereist.
