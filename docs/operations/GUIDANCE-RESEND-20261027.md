# Rondleiding, compacte Google-ingang en Resend — 27 oktober 2026

De oudere Poortkamer-client kon `/` als terugkeerpad meesturen. Op bronrelease dccff090 is de eerste Verder met een geïsoleerd huisaccount gereproduceerd als HTTP 422 / VALIDATION_ERROR. Dit was geen verbindingsfout. Dezelfde browsercontrole slaagt met de reparatie: `/mijn-huis`, HTTP 200, stap 2. Er zijn geen tourversies verhoogd of deelnemers als afgerond gemarkeerd.

De gedeelde padcontrole herstelt oude veilige publieke terugkeerpaden naar de gekozen omgeving en weigert externe, protocolrelatieve, backslash-, control- en te lange paden. De server controleert nog steeds de echte rol. Geldige poortqueries blijven behouden. Automatisch starten gebeurt pas binnen de gekozen omgeving. Bewaren is geserialiseerd; oude reads, rollen en accounts kunnen bevestigde voortgang niet terugzetten. Netwerk, sessie, toegang, validatie, conflict en serverproblemen hebben afzonderlijke feedback en herstel. Alle 14 stappen, versie 1, serverafronding, hervatten, herhalen en aankomstbeveiliging blijven gelden.

De Google-ingang is nu een gelabelde, toetsenbordbedienbare knop van 44 pixels direct onder het e-mailveld bij inloggen, meeloperregistratie en huisregistratie. OTP blijft aanwezig. De bestaande SSR/PKCE-cookieflow en serveridentiteit worden gebruikt. Huisregistratie bewaart alleen de onvoltooide contactvelden lokaal tijdens OAuth; er wordt geen deelname of rol uit clientdata afgeleid. Google is in beide Supabase-projecten ingeschakeld. Een echte voltooide Google-login vereist een gebruiker die de Google-toestemming doorloopt; configuratie is geen bewijs daarvan.

## Mailbeheer en Resend als standaard

De foutmelding in de mailbeheerpagina komt van de extra runtime-toegangslijst MAIL_ADMIN_USER_IDS. De beveiligde staging- en productieconfiguratie is afgestemd op de reeds bestaande, geverifieerde event_admin-gebruikers (respectievelijk 1 en 2). Er zijn geen databasebeheerdersrollen verleend. Zowel de runtime-lijst als de actuele databaseautorisatie blijven verplicht; ouders, poortwachters en overige rollen krijgen hierdoor geen mailbeheerrechten.

De opdrachtgever heeft vervolgens expliciet Resend als standaard gevraagd, met behoud van de uitzondering op alle mailtests. `scripts/deploy/activate-resend-release.mjs` voert daarom uitsluitend voor de exacte geautoriseerde commit een gecontroleerde configuratiewijziging uit, na de gezonde applicatiedeployment. Voorwaarden:

- RESEND_DEFAULT_RELEASE_SHA én MAIL_TEST_WAIVER_SHA komen overeen met GITHUB_SHA; de uitzondering heeft reden en een geldige begrensde vervaltijd.
- Repository, branch, applicatie-URL en Supabase-projectref passen exact bij staging of productie.
- De bestaande verzend- en beheersleutels en eigen webhookconfiguratie zijn aanwezig. Alleen configuratie-GETs controleren het geverifieerde afzenderdomein, uitgeschakelde tracking, eigen webhook-URL, events en overeenkomend signing secret.
- De complete automatische suppressie-import is recent en heeft een bronhash. Ontbrekende import blijft een blokkade; er is geen handmatig exportbestand nodig.
- Een runtime-toegelaten, geverifieerde gebruiker heeft nog steeds event_admin-rechten.

De transactie vergrendelt de actieve configuratie en controleert de verwachte revisie. Een nieuwe onveranderlijke Resend-versie behoudt afzender en reply-to. Bestaande concepten, suppressies, toestemming en oude SendGrid-pogingen blijven bewaard; onbekende pogingen worden niet opnieuw verstuurd. Herhalen is idempotent. Auditactie `mail.config.release_activate` legt commit, reden, vervaltijd, oude/nieuwe versie, mailTestsSkipped=true en deliveryValidated=false vast. Er worden geen testontvangsten, afleverevents of geslaagde controles verzonnen.

De gewone beheer-activatieprocedure met echte testvereisten blijft intact voor toekomstige wijzigingen. Andere commits voeren deze eenmalige release-activatie niet uit. De bestaande bootstrap behoudt daarna de actieve Resend-versie. De mailtestuitzondering blijft uitsluitend aan deze releasecommit gebonden en wordt vóór de eerste push gezet; standaard zijn mailtests ingeschakeld. Levering van OTP, transactionele mail en Nachtpost is voor deze release bewust niet getest.

## Controle

- Nieuwe gerichte tests: gedeelde padcontracten, API-statussen, schrijfreeksen, oude snapshots en contextwissels.
- 18 browserchecks: Chromium desktop en iPhone/WebKit, echte geïsoleerde Supabase-sessies, huis-only/ouder/duale rollen, alle 14 stappen, herladen, afronden, querybehoud, dubbele klik, oude responses, specifieke fouten en compacte Google-knoppen op alle drie ingangen. De tests markeren geen tours vooraf als afgerond.
- Netwerkfouttests blokkeren service workers zodat fetch-interceptie in WebKit deterministisch blijft. De bestaande afzonderlijke PWA/cachechecks blijven actief.
- Een lokale SQL-controle met rollback bewijst behoud van afzender, concept, suppressies en onbekende SendGrid-poging, audit zonder fictieve aflevering, idempotentie en weigering van ontbrekende import. Geen mailgateway of verzendendpoint wordt aangeroepen.
- CI behoudt backup/herstel, migratie-, RLS-, security-, build- en niet-mailcontroles. PR 47 en canonieke hotfixmigratie 20261027033940 blijven in de bronhistorie; voor deze reparatie is geen nieuwe schemawijziging nodig.

Primaire configuratiereferenties: [Resend domeindetails](https://resend.com/docs/api-reference/domains/get-domain), [eigen webhook](https://resend.com/docs/api-reference/webhooks/get-webhook).
