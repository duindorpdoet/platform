# Acteurskamer: bediening, beveiliging en verificatie

Deze module hoort bij de bestaande Halloween-app. Er wordt geen deelnemersinschrijving, kind, betaling of poort gemaakt voor een acteur. De huidige publieke inschrijfstand heeft geen invloed op een acteursuitnodiging. Bronbasis tijdens implementatie: `db5e9fee4fe86aecddbb05b9f0fe6ad3840c66f8`, branch `codex/duinpad-actors-finale-20261031`; het testbewijs benoemt de wijzigingen in deze checkout afzonderlijk van die baseline.

## Organisatie

Open **Beheer → Acteurs & showbediening** als evenementbeheerder (`event_admin`). Naam en e-mailadres zijn voldoende. Nieuwe uitnodigingen beginnen zonder knoppen. Kies daarna per acteur concrete knoppen of een zichtbare preset en sla de rechten op. Presets geven uitsluitend hun getoonde knoppen; globale stop is nooit onderdeel van een preset. De drie zone-stops zijn geïmplementeerd via de beperkte adapter voor interne zones 2, 3 en 4. Heks en finale hebben geen vermomde zonestop.

Uitnodigen maakt één outboxrecord met unieke sleutel `actor-invitation:<invitation-UUID>`. De bestaande mailworker en premiumtemplate versturen `actor_invitation`. Uitnodigingsstatus en mailstatus zijn afzonderlijk. Provideracceptatie betekent nog geen aflevering. In ontwikkeling staan mail en fysieke uitvoer uit; tests gebruiken synthetische adressen en mocks.

Opnieuw uitnodigen maakt een nieuwe nonce, trekt oudere links in, onderdrukt oudere nog te verzenden uitnodigingen en vraagt een nieuwe expliciete activatie van dezelfde identiteit. Intrekken verwijdert de rechten onmiddellijk in de database en verhoogt de revision. De andere omgevingen van hetzelfde account blijven behouden.

## Activering en accountkeuze

De link bevat een onvoorspelbaar HMAC-SHA256-claimtoken in een URL-fragment. Een afzonderlijke serversecret en een cryptografisch willekeurige uitnodigings-UUID leveren de tokenwaarde; alleen de SHA256-hash staat in de uitnodigingstabel. De mail-outbox en de duurzame gateway-envelope bevatten geen claimtoken of claimlink. De worker bevriest uitsluitend niet-geheim mailmateriaal; de gateway bewaart voor dit mailtype alleen het payloadhash. Een herpoging met gewijzigde rendering vereist reconciliatie in plaats van een andere providerpayload onder dezelfde sleutel. De mailworker kan het token met de afzonderlijke uitnodigingssecret opnieuw samenstellen en controleert het opgeslagen hash voordat de gateway wordt aangeroepen.

De claimpagina wist het fragment uit de adresbalk en plaatst via een origin-gecontroleerde POST alleen een hash in een HttpOnly-cookie (SameSite=Lax, Secure onder HTTPS, één uur). Een link openen activeert niets. Inloggen gebruikt de bestaande OTP/Google- en callbackstraat met `safeReturnPath`; het token wordt niet in OAuth-returnpaden gestopt. Ook een reeds ingelogd account moet het getoonde e-mailadres controleren en zelf **Activeer mijn acteursomgeving** kiezen.

De database verifieert `auth.uid()`, het bevestigde huidige e-mailadres uit `auth.users`, de exact genormaliseerde uitnodigingsontvanger, evenement, geldigheid, intrekking en claimstatus onder een lock. Een verkeerd Google-adres krijgt een herstelmelding en kan met het bestaande accountwisselen opnieuw inloggen. Verlopen of vervangen links vragen een nieuwe uitnodiging. Herhaalde claims met dezelfde geldige identiteit leveren dezelfde activatie terug. Er wordt geen identity-merge uitgevoerd. Alleen een actieve koppeling geeft de extra kaart **Acteurskamer** in de bestaande omgevingkiezer en de bestaande herinner-keuze.

## Acteur op locatie

`/omgeving/acteur` toont uitsluitend toegewezen knoppen. De eigen status wordt iedere drie seconden opgehaald als de pagina zichtbaar is, plus bij focus/terugkeer. Een lokale status ouder dan vijf seconden blokkeert bediening. De backend controleert iedere POST opnieuw tegen de actuele database en haalt de huidige lokale groepsselectie op. De browser kan geen groep, scope, interne zone of regierol kiezen.

Gereed vraagt een expliciete ja/nee-keuze. Een druk vraagt eerst uitvoering aan; de bevestiging komt pas na de juiste lokale ACK. Een finalestart vereist dezelfde command-ID, de betekenis `finale_started` en beide velden `qlc_started:true` en `audio_started:true`. Die bevestiging bewijst lokale softwarestarts, geen waarneembaar licht/geluid op locatie of voltooide voorstelling. QR2 en handmatige Finale GO delen het duurzame fysieke groepsslot van de app. Handmatige bediening maakt geen bezoekersscan en begint geen avonddeadline.

Bij offline wordt niets voor later bewaard. Bij timeout, een onderbroken verzoek, een ontbrekende of ongeldige ACK blijft de uitvoering onbekend. Dezelfde actie blijft geblokkeerd totdat een alleen-lezen ontvangst ondubbelzinnig uitsluitsel geeft. **Ontvangst controleren** is een GET en verstuurt nooit een nieuwe opdracht. Na bewezen niet-uitvoering is een nieuwe bewuste druk mogelijk, met een nieuwe ID. Er zijn geen automatische commandoretries, showworkers of show-outbox.

## Protocol en intrekking

Server-only configuratie:

- `DUINPAD_SHOW_API_BASE_URL`: de bestaande echte HTTPS-relayorigin, zonder pad of credentials.
- `DUINPAD_SHOW_API_TOKEN`: bestaande relay-bearer, uitsluitend server/relay.
- `DUINPAD_ACTOR_AUTH_SECRET`: afzonderlijke HMAC-secret, minimaal 32 bytes, ook op de bridge.
- `DUINPAD_EVENT_SCOPE_ID`: de echte app-event-UUID, gelijk aan de bridge-eventbinding.
- `DUINPAD_ACTOR_INVITE_SECRET`: onafhankelijke uitnodigingssecret, minimaal 32 bytes; uitsluitend de bestaande app/mailworker.

Er worden geen secretwaarden of demo-event-ID's meegeleverd. Ontbrekende configuratie levert geen werkende bediening of fictieve uitnodiging op. Secrets komen nooit in `NEXT_PUBLIC_`, QR-codes, browserresponses, auditrecords of foutlogs.

Het geïmplementeerde command gebruikt `duinpad.actor.v1`, de envelope `duinpad.actor-envelope.v1`. `payload` is de base64url van de exacte UTF8-JSON; `signature` is base64url-HMAC-SHA256 over de ASCII-payloadstring. Een opdracht is maximaal acht seconden geldig. Een extra ondertekende `duinpad.actor-access.v1`-grant vervalt na maximaal vijf seconden. De header `X-Duinpad-Actor-Grant` bevat de base64url-JSON-envelope. Alle relaypaden blijven achter de bestaande bearer en eventbinding:

- `POST /api/integration/actor-command`: een actuele, concrete uitvoeringspoging.
- `GET /api/integration/actor-status`: uitsluitend eigen controls en hun lokale redenen.
- `POST /api/integration/actor-access`: uitsluitend revision/intrekkingsstatus, geen showactie.
- `GET /api/integration/receipts/<id>?kind=actor&payload_hash=<sha256>[&group_id=<id>]`: immutable ontvangst, zonder uitvoering.

De bridge bewaart de hoogste revision duurzaam, controleert grant/revision opnieuw onder de controller- en capabilitylock en verwerkt intrekkingen ook terwijl een opdracht op de controllerlock wacht. Een positieve intrekkings-ACK volgt pas na de duurzame lokale update. De backend meldt een mislukte synchronisatie niet als lokaal bevestigde intrekking. Nieuwe browser-POSTs verliezen direct hun DB-recht; een reeds uitgegeven grant kan bij onbereikbare push maximaal vijf seconden blijven gelden. Dit is de expliciete grens van het netwerkprotocol: er wordt geen onmiddellijke gedistribueerde intrekking geclaimd wanneer de bridge geen bevestiging kon leveren. Een reeds lopende cue wordt alleen met een afzonderlijk stoprecht of lokale regieprocedure gestopt.

De status gebruikt een veld-whitelist. Geen deelnemers, andere actorrechten, DMX-/audio-instellingen of globale `next_intro`/`next_finale`-velden worden doorgestuurd. De aparte actor-migratie schakelt RLS in en trekt alle directe tabelrechten en onbegrensde helperrechten in. Alleen narrow, geautoriseerde RPC's worden aan `authenticated` toegekend; ontvangstvastlegging en mailmateriaal zijn uitsluitend voor de vertrouwde backend/worker.

## Herstel

Bij unknown eerst de bestaande ontvangst ophalen. Een receiptmiss is geen bewijs van niet-uitvoering en maakt geen nieuw command vrij. Na een lokale herstart blijft interrupted/recovery_required geblokkeerd. Controleer lokaal de regie, QLC en audio volgens de bridgehandleiding; hervat geen tijdlijn.

Voor een onzekere finale bevat de lokale regie een afzonderlijke `resolve_finale_not_executed`-afhandeling met de exacte poging-ID, expliciete bevestiging van gecontroleerde niet-uitvoering en reden. Deze levert een duurzaam geaudit ontvangstbewijs op. De app haalt dat uitsluitend via het receiptpad op en reconcilieert daarmee zowel de eigen actorontvangst als het gedeelde groepsslot. Een historisch gestarte finale wordt nooit met deze handeling vrijgemaakt. Groepsreset, opnieuw inloggen, partijwissel en uitnodigingsrotatie leveren geen tweede groepsshow op.

## Uitvoerbare verificatie en grenzen

```sh
pnpm exec vitest run lib/duinpad/actor-protocol.test.ts app/api/actors/command/route.test.ts app/api/actors/claim/route.test.ts app/api/jobs/mail/route.test.ts lib/mail/templates.test.ts
node scripts/acceptance/duinpad-browser.mjs
# Alleen op de eigen synthetische DB, nadat de compatibele migraties zijn toegepast:
psql "$DUINPAD_SYNTHETIC_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/110_duinpad_actor_access.sql
```

De browserharness bundelt de echte componenten buiten de productieroutes, op een tijdelijke lokale HTTP-server, met synthetische endpoints. Er wordt geen mockroute aan de productieapp toegevoegd. `test-results/duinpad-browser/report.json` bevat bronbasis, tijdstip en concrete checks. De geselecteerde screenshots en het bewijsrapport staan naast deze handleiding. Deze browserproef dekt 320/390px, toetsenbord, grote tikvlakken, geen horizontale overflow, reduced motion, beperkt rechtenbeeld, unknown/herstel zonder POST, intrekking bij focus, stale status, tweestapsfinalescan, kind overslaan met expliciete keuze, serverafsluiting en twee afzonderlijke posters met losse verbindingsstatus.

De acteur-pgTAP-suite draait in BEGIN/ROLLBACK en dekt 60 assertions: geen nieuwe deelnemersobjecten, alleen hashes, afgesloten tabellen/RPC's, geen automatische activatie, exact bevestigde identiteit, verlopen/vervangen link, idempotente claim, geen globale stopalias, verse rechten, immutable commandpayload, unknownblokkade, eigen receipt, heruitnodigen, intrekking met dezelfde JWT, accountkeuze en gateway-revalidatie. Tests versturen geen echte e-mail en raken geen hardware. Echte Google-accounts, daadwerkelijke OTP-ontvangst, afleverwebhooks, productie-auth/deployment en fysieke licht-/audio-/noodstopproeven moeten door de bestaande release- en locatieprocedure worden bewezen; die zijn hier niet als uitgevoerd gemarkeerd.
