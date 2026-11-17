# Lokale diagnose HUI02 na de gepubliceerde parentfailure

Op 3 november 2026 om 09:18 UTC is uitsluitend het relevante HUI02-prefix uit de parentacceptatie opnieuw uitgevoerd tegen de ongewijzigde lokale productiebuild `hanzA2t5Xaby269LUnhWK`, bron `d8439e09c67083548d8b09ac4110d24820a52dd0`. Dit verklaart de gepubliceerde failure nog niet en is geen geslaagde hosted HUI02-proef.

Een nieuwe private sibling gebruikte de bestaande synthetische QAbeheerder en bewoner via de normale SSR-accountflow. Er zijn geen Auth-accounts aangemaakt, verwijderd of geblokkeerd en geen wachtwoorden gewijzigd. Een reguliere tokenverversing door `setSession` is niet uitgesloten; de Auth-behoudsvergelijking bewijst bestaande IDs, niet onveranderde sessierijen. Alleen een nieuw eigen huis in deze kopie werd aangemeld, contact-/locatiebevestigd en als synthetisch gemarkeerd; er waren geen betalingen, OTP, externe requests of mail.

De exacte versieketen en HTTP-uitkomsten waren:

| Stap | Verwachte versie | HTTP / code | Huisversie na stap |
| --- | --- | --- | --- |
| Begin, bevestigd huis in beoordeling | — | — | 3 |
| Wijziging vragen zonder reden | 3 | 409 `REVIEW_REASON_REQUIRED` | 3 |
| Werkelijke regie-UI: Wijziging vragen met reden | 3 | 200, resultaat versie 4 | 4 |
| Aparte goedkeuring met dezelfde oude versie | 3 | 409 `VERSION_CONFLICT` | 4 |

De oude goedkeuring veranderde geen status, reden of versie. De oorspronkelijke parentassertie `staleReview.status === 409` zou hier dus slagen. De volledige UI-payload, het serverresultaat, de gecontroleerde huisprojecties vóór/na beide aanvragen en de foutcodes staan in `report.json`.

Cleanup archiveerde alleen de eigen synthetische run, sloot de nieuwe sibling en trok diens beheerdercapability in. Alle bestaande Auth-IDs, financiële rijen en de legacy-outbox bleven ongewijzigd. Er zijn geen product-, migratie- of permanente acceptatiebronwijzigingen gemaakt.

De daadwerkelijke harnessbron, twee diagnostische screenshots en vijf bronhashen zijn opgenomen. `source-binding.json` vergelijkt die hashes met de exacte gitobjecten en controleert de werkelijk geserveerde build-ID.
