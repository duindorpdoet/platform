# Redesign: productiepromotie in uitvoering

Stand: 23 oktober 2026. De gebruiker heeft expliciet opdracht gegeven alles naar productie te promoveren. De vier additieve migraties staan op staging; de appuitrol wacht nog op alle releasecontroles. Productie is nog niet gepromoveerd. Deze status is geen volledige visuele of fysieke acceptatie.

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

## Aanvullend bewezen tijdens de promotie

- Geldige projecttoegang is beschikbaar binnen de bestaande beschermde GitHub Actions-omgevingen. Er zijn geen privileges of geheimen uit die omgevingen naar de ontwikkelmachine gekopieerd.
- [Stagingherstelproef 39959674132](https://github.com/duindorpdoet/platform/actions/runs/39959674132): echte PostgreSQL `17.6.1.166`, 56 bestaande migraties, alle 169 gecontroleerde tabellen identiek hersteld en 12 opslagobjecten versleuteld veiliggesteld. De vier migraties duurden op de kopie respectievelijk 85, 79, 64 en 64 ms; de bestaande rijen bleven gelijk.
- [Herhaalde herstelproef 39961001628](https://github.com/duindorpdoet/platform/actions/runs/39961001628): na de expand-stap 176 tabellen identiek hersteld, 12 opslagobjecten en alle vier migraties opnieuw geslaagd. Volledige uitrol van deze tussentijdse SHA was niet geslaagd; een herstelproef is afzonderlijk bewijs.
- De backupstroom en opslagobjecten zijn AES-256-GCM-versleuteld; het getekende bewijs bevat hashes van precies de geteste migraties. Alleen versleutelde bestanden en het niet-gevoelige bewijs gaan naar Actions-artifacts. De dedicated deployrunner bewaart daarnaast een privéversie onder het eigen account.
- [Applicatiecontrole a401b138](https://github.com/duindorpdoet/platform/actions/runs/39958925378): lint, TypeScript, 274 unitcontroles in 47 bestanden, productiebouw, artifactscan en 50 publieke browsercontroles geslaagd. De andere job van die workflow is later vervangen door een nieuwere SHA; de gehele workflow geldt dus niet als geslaagd.
- [Gerichte ingelogde controle a401b138](https://github.com/duindorpdoet/platform/actions/runs/39958922902): negen mobiele/navigatie-/privacycontroles met echte lokale Supabase-services geslaagd. De uitgebreidere suites blijven afzonderlijk vereist.
- De volledige SQL-suite is ook op echte lokale Supabase-services in Actions uitgevoerd: 62 bestanden, 1.652 controles geslaagd. OTP, echte parallelle transacties, samenloopconcurrentie en de 200-clientproef zijn geslaagd. Dit is geen fysieke telefoonproef of gehoste productieacceptatie.

## Openstaande acceptatie

De volledige opdracht heeft ruimere acceptatievoorwaarden dan alleen een geslaagde deployment. Alle 66 regels zijn nog niet integraal op gehoste staging afgetekend. Pixelperfecte gelijkheid is niet aangetoond: publieke geometrie is deels gemeten, maar fontmetriek wijkt af en passende beelden ontbreken nog voor een deel van de ingelogde toestanden. Zie [VISUEEL.md](VISUEEL.md). Fysieke zwart-witafdruk, camera/papier, mobiel bereik en de volledige toegankelijkheidscontrole staan eveneens open. Vermeld deze grenzen bij de uiteindelijke oplevering.

Er zijn geen live databases gereset of geseed en geen bestaande credentials geroteerd. Op staging zijn de vier expand-migraties toegepast; historische backfill wordt niet automatisch uitgevoerd. Iedere onverklaarde wijziging van bestaande domeingegevens blijft de appuitrol blokkeren. Migratiehistorie en normale cronactiviteit worden apart gereconcilieerd, met behoud van bestaande historie.
