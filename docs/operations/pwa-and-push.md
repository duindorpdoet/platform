# PWA en Web Push

De persoonlijke omgeving is installeerbaar vanaf `/omgeving`. Het manifest gebruikt `/omgeving` als stabiele app-id en startpagina. De service worker bewaart alleen de expliciet genoemde publieke merkbestanden, de appiconen, het manifest, de neutrale offlinepagina en onveranderlijke `/_next/static/`-bestanden. Ingelogde documenten, RSC-responses, API-antwoorden, sessies en persoonsgegevens gaan altijd rechtstreeks naar het netwerk.

## GitHub Environments

Configureer voor `staging` en, vóór een latere productiepromotie, afzonderlijk voor `production`:

| Naam | GitHub-type | Waarde |
| --- | --- | --- |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | Environment variable | URL-safe Base64 publieke VAPID-sleutel |
| `VAPID_PRIVATE_KEY` | Environment secret | Bijbehorende privésleutel; nooit in broncode of client-runtime |
| `VAPID_SUBJECT` | Environment variable | `mailto:halloween@duindorpdoet.nl` |

Maak per omgeving een apart sleutelpaar met `pnpm exec web-push generate-vapid-keys --json`. De publieke sleutel wordt tijdens de Next.js-build in de browsercode opgenomen. De privésleutel komt alleen als server-runtimevariabele beschikbaar. Het deploymentcontract weigert een release als een van deze drie waarden ontbreekt.

De afgeschermde testpush staat alleen op staging open. De route autoriseert de bestaande Supabase-sessie via `admin_access_snapshot`, verstuurt uitsluitend naar actieve abonnementen van de ingelogde beheerder en schrijft alleen een neutrale melding. HTTP 404 en 410 van de pushdienst deactiveren het verlopen abonnement.

## Acceptatie op echte apparaten

Deze controles moeten met een staging-testaccount worden uitgevoerd. Gebruik geen account of pushabonnement van een echte deelnemer.

### iPhone Safari

1. Open staging in Safari, log in via de bestaande OTP-flow en controleer dat de installatie-uitnodiging eenmaal verschijnt.
2. Tik `Installeer app`; controleer dat de uitleg `Deel` → `Zet op beginscherm` toont.
3. Voeg de app toe, open haar via het icoon en controleer opstartbeeld, veilige schermranden, onderste navigatie en start op `/omgeving`.
4. Controleer of de sessie blijft werken na volledig afsluiten, opnieuw openen en een toestelherstart. Log zo nodig eenmalig in de geïnstalleerde app in op een iOS-versie die de browsersessie niet overneemt.
5. Vink de pushvoorkeur aan en tik daarna afzonderlijk `Meldingen aanzetten`. Controleer dat de status pas na systeemtoestemming en serveropslag actief wordt.
6. Laat een beheerder op hetzelfde testaccount de staging-testpush uitvoeren. Controleer de neutrale tekst en dat een tik `/omgeving` opent en daar opnieuw autoriseert.

### Samsung Chrome en Samsung Internet

Voer dezelfde stappen afzonderlijk in Chrome en Samsung Internet uit. Controleer de echte `beforeinstallprompt`-installatie wanneer beschikbaar en anders de browserspecifieke menu-uitleg. Controleer standalone openen, sessiebehoud, interne links, push aan/uit en een staging-testpush.

### Privacy en groepsstart

1. Open als account A een vrijgegeven groepsopdracht, log uit, verbreek het netwerk en log/open daarna als account B. Geen pagina, adres of snapshot van A mag zichtbaar zijn.
2. Controleer dat privé-HTML, `/api/*` en RSC-responses nooit in Cache Storage staan.
3. Laat de groepsleider ieder kind afzonderlijk op aanwezig of afwezig zetten. Starten blijft geblokkeerd bij `X < Y`, bij nul aanwezigen, offline, voor een andere gebruiker en bij een verouderde groepsversie.
4. Wijzig de groepslijst en laad opnieuw. Een nieuw kind mag niet stil als aanwezig worden geselecteerd.

Fysieke apparaattests kunnen niet vanuit de CI-runner worden uitgevoerd. Noteer bij de PR per browser toestelmodel, OS-versie, resultaat en eventuele schermafbeelding; zonder die registratie geldt apparaatondersteuning als **niet fysiek geverifieerd**.
