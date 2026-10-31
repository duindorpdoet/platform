# Poortenboek refreshhotfix — 31 oktober 2026

Alle genoemde tijden zijn Europe/Amsterdam. Alleen fase 1 verandert de applicatie;
er is geen databasemigratie, wijziging van spelregels, compute of globale timeout.

## Oorzaak en begrenzing

De productiecode had onafhankelijke 12-secondenpolling, 1,5-secondenherstel en
eventrefreshes zonder in-flight guard. De sequenceguard verwierp alleen antwoorden.
Ook de kinduitleg deed een zelfstandige snapshotfetch. Trage snapshots versterkten
zo de wachtrij op dezelfde sessie. Dit is geen bewijs dat alle uitval hierdoor komt.

Eén coordinator per gemount boek omvat nu fetch, body, validatie en state-afhandeling.
Triggers delen maximaal één actief en één vervolgslot. Polling begint 12 seconden
na afronding. Fouten geven 5/10/20/30 seconden basisbackoff met maximaal 20% positieve
jitter en een totale cap van 30 seconden. Een grotere Retry-After blijft leidend.
Alleen een geldige snapshot voor dezelfde kind-/event-/sessie-identiteit reset dit.
401/403, gewijzigde identiteit en expiry stoppen ophalen en volgen de loginroute.

HTTP-reads hebben een deadline van 15 seconden; de actieve guard blijft staan tot
de hele operatie eindigt, ook als een transport abort negeert. Request.signal gaat
via GET -> childSnapshot -> childRpc -> de geïnstalleerde Supabase .abortSignal().
De servertimer begrenst ook een snapshot zonder browserdisconnect. De reverse proxy
kan doorgifte van een browserdisconnect beïnvloeden. Transportannulering bewijst
geen annulering van de PostgreSQL-transactie. Dit is geen globale databaselockfix:
twee tabbladen of apparaten houden ieder hun eigen coordinator en blijven samen
belasting veroorzaken. Bestaande SQL-locks blijven in fase 1 bestaan.

Verbergen, offline gaan, storagewijzigingen, logout, sessiewissel en unmount
maken reads ongeldig. De bestaande privacyschermen gaan voor oude data. Een tijdelijke
netwerk-/5xx-fout houdt uitsluitend de laatst bevestigde data van dezelfde nog
geldige sessie vast, met een melding. De sessie-expirytimer blijft ook zonder
zichtbare snapshot actief. De kinduitleg gebruikt de verse coordinatorsnapshot.

Mutaties krijgen geen snapshotabortsignaal en worden niet automatisch herhaald.
Hun payloads en requestId blijven behouden. De checklist toont pas een wijziging
na serverbevestiging. Bij een onbekende uitkomst verschijnt een melding en volgt
alleen een gebundelde read; de gebruiker moet de bevestigde stand controleren.

## Verificatie en uitrol

- Unit: `pnpm exec vitest run lib/poortenboek app/api/poortenboek --maxWorkers=2`.
- Browser zonder database: `pnpm exec playwright test --config playwright.poortenboek-refresh.config.ts`.
  Het echte boek en de kinduitleg draaien in Strict Mode; alleen transport en Next
  routing zijn gecontroleerde testdoubles. De klok, headers en body zijn stuurbaar.
- Project: `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build`, `pnpm test:artifacts`.
  De browsercheck is ook aan de bestaande application-CI toegevoegd.
  Lokaal resultaat: lint/typecheck geslaagd, 1.190 unittests geslaagd en één
  overgeslagen, 14 browsertests geslaagd, productiebuild geslaagd en PRIV-08
  artifactscan geslaagd voor 1.344 bestanden. De eerste volledige testsuite had
  vijf routeplanner-timeouts tijdens lokale geheugenbelasting; de geïsoleerde
  plannerherhaling en volledige herhaling met twee workers slagen zonder
  aangepaste test- of applicatietimeouts. De build draaide met dezelfde gelockte
  dependencies in een tijdelijke volledige kopie wegens de lokaal volle schijf.
- Bestaande releasevolgorde: groene CI, exact dezelfde SHA naar staging, controleer
  daadwerkelijke deployment en acceptatie, vervolgens dezelfde SHA naar production.
  Geen releasegates of mailcontroles overslaan als onderdeel van deze hotfix.
- Controleer de werkelijke revision via `/api/health`, de GitHub deploymentstatus en
  één bestaande gecontroleerde echte sessie. Observeer maximaal één GET tegelijk,
  geen 1,5-secondenverzoeken bij fout, oplopende herstelpauzes en geen polling verborgen.
  Gebruik geen productieloadtest of automatische mutatieherhaling.
- Vraag gebruikers met een al geopend boek de pagina eenmaal te herladen zodra de
  nieuwe release actief is. Geen globale service-worker- of cachewipe.
- Vergelijk één klein voor-/navenster via beschikbare logs: aantallen, latency en
  5xx voor Poortenboek/guidance/room en bereikbaarheid van Auth/deelnemersapp.
  RPC-tellingen bevatten ook mutaties en zijn dus geen zuivere snapshotfrequentie.
  Claim geen productieherstel zolang echte sessie- en navenstermeting ontbreken.

## Baseline en rollback

Supabase `dtubngvxfbupgvgfrjko` meldde bij deze audit ACTIVE_HEALTHY; compute is niet
vastgesteld. Het logsvenster 17:08:51–17:13:51 gaf Poortenboek 14 RPC-verzoeken/11
HTTP-5xx, guidance 36/23, room 4/2 en Auth 273/13. SQLSTATE 57014: respectievelijk
6/10/1 voor de drie RPC-paden. De geselecteerde logs bevestigen queryannulering;
de precieze statement-timeoutmelding en latency-eenheid zijn hiermee niet bewezen.
De aanvankelijke controle van `/api/health/deployment` liep na 15 seconden af;
dit is geen bestaand healthendpoint. De juiste `/api/health` gaf daarna HTTP 200
in 0,174 seconden en bevestigde environment=production en onderstaande revision.
Dit endpoint leest geen database en bewijst geen herstel van Auth of de deelnemersapp.

De vooraf succesvolle productierelease is
`db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`, deployment 7455963021,
[run 41180959245](https://github.com/duindorpdoet/platform/actions/runs/41180959245).
Rol bij een regressie via de bestaande immutable Sites-release-interface terug
naar deze revision en verifieer `/api/health`, publieke/private routes en no-store.
Geen force-push, reset, databaseherstart of dataverwijdering. Er is geen migratie
om terug te draaien; sessies, stemmen en voortgang blijven behouden.

## Gerichte vervolghotfix voor fase 2

Eén begrensde cataloguitlezing legde 30 werkelijk geïnstalleerde functies vast.
De actieve keten bevat event FOR SHARE, sessie FOR UPDATE, verkiezingsdefaults,
team-advisorylocks, verkiezingsadvance, progress-/identity-/chapterinserts en
resolve_banner met writes/locks. Latere wrappers behouden dit gedrag. Sommige
wrappers zijn al STABLE; dat bewijst hier geen volledig lezend pad.

Een vervolgfix moet leesvalidatie scheiden met behoud van alle token-, binding-,
expiry-, revocation-, kind-/team- en autorisatiecontroles. Initialisatie moet naar
login/parent-open/echte mutaties; tijdige verkiezingsafloop en vaandelresultaten
vereisen een gecontroleerde afhandelaar. Er is geen bestaande zelfstandige worker
gevonden die dit al overneemt. Alleen locks of writes verwijderen kan spelregels
breken en is daarom niet meegenomen. Hiervoor zijn een nieuwe beperkte migratie,
autorisatie-/concurrencyregressies en vooraf bewaarde functiedefinities nodig.
Geen SECURITY DEFINER, extra rechten of speculatieve productiepatch toegevoegd.
