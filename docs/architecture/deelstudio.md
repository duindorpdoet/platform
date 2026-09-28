# Deelstudio — architectuur en oplevering

## Resultaat

De gebruikersactie **Deel de magie** opent `/deel-de-magie`. De pagina toont alleen kaarten die de server voor de huidige volwassene of anonieme bezoeker vrijgeeft. De admin beheert de versievaste templates onder **Communicatie → Deelstudio**. Iedere gegenereerde kaart heeft het officiële logo, lokale gebundelde fonts en een gecureerde achtergrond.

De veilige openbare landingspagina is `/delen/[publicShareId]`. Persoonlijke en rolgebonden varianten krijgen `noindex`; staging krijgt altijd `noindex`. Open Graph gebruikt een afzonderlijke 1200 × 630-render.

## Renderarchitectuur

- `sharp` maakt deterministische PNG-bestanden op de server; er wordt geen browser-screenshot gebruikt.
- Een lokale WebP wordt als `cover` uitgesneden en krijgt een SVG-overlay met scrim, typografie, logo, veilige waarden en optionele QR.
- DejaVu Serif Bold en Sans Bold zijn lokaal gebundeld onder `public/fonts`; hun licentie staat ernaast.
- Het echte `public/images/logo.webp` wordt als afzonderlijke compositielaag geplaatst. Een beeldmodel maakt geen logo of tekst.
- Het renderbudget is 15 seconden. Cachekeys bevatten template-ID/versie, formaat, stijl en de gecanoniseerde veilige payload.
- QR-codes accepteren uitsluitend HTTPS (of localhost in ontwikkeling), exact dezelfde geconfigureerde origin en een servergemaakte openbare deelroute.
- Staging-renders krijgen zichtbaar het watermerk `STAGING`.

## Kaarten en formaten

De migratie publiceert versie 1 van elf kaarten: Wij lopen mee, Wij zijn een Poort, Loop jij met ons mee?, Word ook een Poort, Help mee bij onze Poort, Ons team is klaar voor de nacht, Onze wereld ontwaakt, Aftelkaart, Terugblik deelnemer, Terugblik poort en Algemene eventkaart.

Ieder type ondersteunt Story (1080 × 1920), Feed (1080 × 1350), Vierkant (1080 × 1080), Liggend (1600 × 900) en Open Graph (1200 × 630). Twee bronbeelden per type sturen portrait- en landscape-uitsneden.

Bewijsrenders staan in `docs/screenshots/deelstudio`: één Story-voorbeeld per kaarttype en alle vijf formaten van de algemene eventkaart.

## Autorisatie en privacy

Alle tabellen staan in `app_private`, hebben RLS aan en zijn ingetrokken voor `anon` en `authenticated`. Browsers gebruiken uitsluitend kleine `api`-projecties. De service-rolekey blijft in de serverroute.

- Een ingelogde volwassene wordt afgeleid uit de geverifieerde Auth-claims, nooit uit requestdata of `user_metadata`.
- Deelnemers worden via het eigen actieve huishouden en de eigen ingediende inschrijving geselecteerd.
- Alleen het huishouden dat het samenloopcluster heeft gemaakt krijgt de samenloopkaart. Code, clusterreferentie, leden en capaciteit verlaten de databaseprojectie niet.
- Teamnaam en vaandel komen alleen uit een afgeronde verkiezing en definitief vaandel. Kindcodes hebben geen share-endpoint of share-recht.
- Poortkaarten komen alleen uit de eigen aanvraag/eigenaarstoegang. Wereldnaam, kleur en poortnaam komen pas uit een actieve, goedgekeurde presentatie.
- De serverprojectie bevat geen kindnamen, leeftijden, adressen, telefoons, e-mails, routes, startpunten, exacte starttijden of interne codes.
- Templatepublicatie weigert externe/traversing assets, HTML, onbekende placeholders, bekende samenloopcodes, e-mails, telefoonnummers, postcodes, exacte tijden en tekst over een laatste/eindpoort.
- Publieke IDs en Storage-objectnamen zijn willekeurig en bevatten geen persoonsgegevens.

## Opslag en retentie

De private bucket `social-share-assets` scheidt `temporary/[uuid]/...` van `public/[random-id]/opengraph.png`. Downloadassets verlopen na 90 dagen (of minimaal twee dagen na het evenement). Publieke OG-assets en deelpagina’s verlopen na één jaar. De bestaande geauthenticeerde cronworker verwijdert eerst de Storage-objecten en finaliseert daarna idempotent de databasestatus. Extern opgeslagen of opnieuw geplaatste bestanden kunnen vanzelfsprekend niet worden ingetrokken.

## Analytics

De funnel bewaart alleen event, template, optionele privacyvriendelijke actor/session, expliciet gekozen platform en tijdstip. Er worden geen IP-adressen of volledige user agents bewaard. `native_share_opened` betekent uitsluitend dat het systeemdeelmenu is geopend; de UI en admin claimen niet dat een bericht werkelijk is geplaatst.

## Platformgedrag

- Native Web Share met bestand wordt uitsluitend na een klik en na `navigator.canShare({ files })` gebruikt.
- Bij ontbreken daarvan worden afbeelding en tekst klaargezet voor handmatige plaatsing.
- Facebook en X krijgen een veilige deelpagina met dynamische OG-metadata.
- Instagram, Snapchat en WhatsApp blijven afhankelijk van OS/browser-appkoppeling; downloaden en kopiëren blijven altijd beschikbaar.
- V1 vraagt geen socialmedia-accounttoegang, tokens of automatische plaatsingsrechten.

## Configuratie

Er zijn geen nieuwe environmentvariabelen. De feature gebruikt de bestaande `APP_URL`, `APP_ENVIRONMENT`, Supabase servercredentials en `CRON_SECRET`. Achtergronden zijn lokale, versiebeheerbare assets; er is geen tweede mediabibliotheek.

## Belangrijke bestanden

- `supabase/migrations/20260928193518_social_share_studio.sql` — datamodel, projecties, RLS, versiebeheer en retentiecontract.
- `lib/social-share/render.ts` — serverrenderer en QR/assetvalidatie.
- `app/api/deelstudio` — context, generatie, private Storage-proxy en analytics.
- `components/social-share/share-studio.tsx` — mobiel-eerste generator en deel/downloadfallback.
- `components/admin/share-studio-admin.tsx` — templateversies, perioden, assets en funnel.
- `app/delen/[id]/page.tsx` — veilige deelpagina en metadata.
- `supabase/tests/055_social_share_studio.sql`, `lib/social-share/render.test.ts` en `tests/e2e/deelstudio.spec.ts` — database-, render-, privacy- en browsercontracten.
