// Exact published-SHA acceptance only. Reuses the parent's newly created
// .invalid actors, creates one sibling and preserves Auth/financial history.
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

export async function runEdgeAcceptance({ base, slug: parentSlug, eventId: parentEventId, run, admin, a, b, resident, support, sql, app, assert, checked, literal, report, directory }) {
  assert(base === 'https://staging-halloween.duindorpdoet.nl', 'EDGE_STAGING_ORIGIN_REQUIRED');
  assert(/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA ?? '') && process.env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA === process.env.GITHUB_SHA, 'EDGE_VERIFIED_RELEASE_REQUIRED');
  assert(process.env.FRIGHTNIGHT_PAYMENT_PROVIDER === 'contract', 'EDGE_CONTRACT_ONLY_REQUIRED');
  assert(parentSlug.startsWith('frightnight-2027-test-acceptance-') && UUID.test(parentEventId), 'EDGE_PARENT_SCOPE_REQUIRED');
  const people = [admin, a, b, resident, support];
  assert(people.every(person => UUID.test(person.id) && person.email?.endsWith('@example.invalid') && person.context), 'EDGE_EXISTING_INVALID_ACTORS_REQUIRED');
  const ids = people.map(person => `${literal(person.id)}::uuid`).join(',');
  const actorProof = await sql(`select count(*)::integer n from auth.users where id in(${ids}) and email like '%@example.invalid' and raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}`);
  assert(Number(actorProof[0]?.n) === people.length, 'EDGE_ACTOR_RUN_BINDING_REQUIRED');
  const slug = `${parentSlug}-edge-${randomUUID().slice(0, 8)}`;
  assert(slug.length <= 100 && /^[a-z0-9-]+$/.test(slug), 'EDGE_SLUG_INVALID');
  const detail = { revision: process.env.GITHUB_SHA, edition: slug, startedAt: new Date().toISOString(), status: 'running', cases: [], limits: ['Synthetic paid route fixtures are not provider payment confirmations.', 'Synthetic walking minutes do not prove real street geometry or physical feasibility.', 'Browser reload is not a VPS process restart.', 'Digital rehearsal does not verify physical beacon hardware.', 'No OTP, Mollie, outbound mail, push or new Auth identities.'] };
  report.edgeAcceptance = detail;
  const startingChecks = report.checks.length;
  const parentBefore = await sql(`select md5(to_jsonb(f)::text) digest from app_private.fn_events f where event_id=${literal(parentEventId)}::uuid`);
  const contexts = [];
  const pages = [];
  let eventId;
  let runId;
  let failure;
  let pageErrors = 0;
  const pass = (id, label, values = {}) => { checked(`${id} ${label}`, { module: 'package-edges', edition: slug, ...values }); detail.cases.push({ id, label, status: 'passed', ...values }); };
  async function select(person, selectedSlug = slug) {
    const response = await person.context.request.post(`${base}/api/frightnight/edition`, { headers: { Origin: base }, data: { slug: selectedSlug } });
    assert(response.ok() && (await response.json()).data.selected === selectedSlug, 'EDGE_SIGNED_SELECTION_FAILED');
  }
  async function state(person) {
    const response = await person.context.request.get(`${base}/api/frightnight/snapshot`);
    assert(response.ok(), 'EDGE_SNAPSHOT_FAILED');
    const value = (await response.json()).data;
    assert(value.event.id === eventId && value.event.slug === slug && value.event.test && value.event.environment === 'staging', 'EDGE_EFFECTIVE_SCOPE_MISMATCH');
    return value;
  }
  const command = (person, operation, payload = {}, allowFailure = false, key = randomUUID()) => app(person, operation, payload, key, allowFailure);
  async function reject(person, operation, payload, statuses = [403, 409, 422], key) {
    const result = await command(person, operation, payload, true, key);
    assert(statuses.includes(result.status) && !result.value?.ok && result.error?.code, 'EDGE_EXPECTED_COMMAND_REJECTION');
    return result;
  }
  async function fixture(body) {
    assert(UUID.test(eventId) && UUID.test(runId), 'EDGE_FIXTURE_SCOPE_REQUIRED');
    await sql(`do $$ declare eid uuid; own_run uuid; begin
      select e.id,f.run_id into eid,own_run from app_private.events e join app_private.fn_events f on f.event_id=e.id
      where e.id=${literal(eventId)}::uuid and e.slug=${literal(slug)} and f.run_id=${literal(runId)}::uuid and f.environment='staging' and f.is_test and not f.closed;
      if eid is null or (select count(*) from auth.users where id in(${ids}) and email like '%@example.invalid' and raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})<>5 then raise exception 'EDGE_FIXTURE_BINDING_REQUIRED'; end if;
      ${body}
    end $$`, true);
  }
  async function settings(values) {
    const s = await state(admin);
    return command(admin, 'admin.settings', { ...values, expectedVersion: s.event.version, reason: 'Afzonderlijke synthetische pakketacceptatie met expliciete editiegrens', ...(values.closed ? { confirmation: slug } : {}) });
  }
  const clock = time => command(admin, 'test.clock', { time });
  async function code(zoneId) {
    const response = await admin.context.request.get(`${base}/api/frightnight/qr${zoneId ? `?zoneId=${encodeURIComponent(zoneId)}` : ''}`);
    assert(response.ok(), 'EDGE_QR_EXPORT_FAILED');
    const value = (await response.text()).match(/<code>([^<]+)<\/code>/)?.[1];
    assert(value, 'EDGE_QR_MANUAL_CODE_MISSING');
    return value;
  }
  async function pageFor(person, path = '/nachtpas') {
    const page = await person.context.newPage(); pages.push(page);
    page.on('pageerror', () => { pageErrors++; });
    await page.goto(`${base}${path}`, { waitUntil: 'domcontentloaded' });
    await page.locator('.fn-environment-nav').waitFor();
    return page;
  }
  async function reload(page) { await page.reload({ waitUntil: 'domcontentloaded' }); await page.locator('.fn-environment-nav').waitFor(); }
  async function screen(page, name) {
    for (const width of [390, 1440]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });
      assert(!await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), 'EDGE_RESPONSIVE_OVERFLOW');
      const file = `${name}-${width}.png`;
      await page.screenshot({ path: join(directory, file), fullPage: true, mask: [page.locator('#fn-scan-dialog input'), page.locator('.fn-invite')] });
      report.screenshots.push(file);
    }
  }
  async function browserCommand(page, operation, action) {
    const waiting = page.waitForResponse(response => new URL(response.url()).pathname === '/api/frightnight/command' && response.request().method() === 'POST' && response.request().postDataJSON().operation === operation);
    const [response] = await Promise.all([waiting, action()]);
    return { response, command: response.request().postDataJSON() };
  }
  async function beginScan(page, token) {
    await page.getByRole('button', { name: 'Scan bij deze bestemming', exact: true }).click();
    await page.getByLabel('Of voer de code van het bord in').fill(token);
  }
  async function scan(page, token) {
    await beginScan(page, token);
    return browserCommand(page, 'journey.complete', () => page.getByRole('button', { name: 'Controleer code', exact: true }).click());
  }
  async function copyContext(person) {
    const context = await person.context.browser().newContext({ storageState: await person.context.storageState(), serviceWorkers: 'block', reducedMotion: 'reduce', viewport: { width: 390, height: 844 } });
    contexts.push(context);
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      return /\/auth\/v1\/(otp|magiclink|recover|signup|invite)|\/api\/push\/test|\/api\/mail\//.test(url.pathname) || /(^|\.)mollie\.com$/.test(url.hostname) ? route.abort() : route.continue();
    });
    return { ...person, context };
  }
  async function pending(page) {
    return page.evaluate(selectedSlug => {
      const key = Object.keys(localStorage).find(name => name.startsWith('duindorp-private-group:frightnight-v1:') && name.endsWith(`:${selectedSlug}`));
      const value = key ? JSON.parse(localStorage.getItem(key)) : null;
      return { id: value?.pending?.commandId, operation: value?.pending?.operation };
    }, slug);
  }
  async function financial() {
    return (await sql(`select (select md5(coalesce(jsonb_agg(to_jsonb(o) order by id)::text,'')) from app_private.fn_orders o where event_id=${literal(eventId)}::uuid) orders,(select md5(coalesce(jsonb_agg(to_jsonb(l) order by id)::text,'')) from app_private.fn_ledger l where event_id=${literal(eventId)}::uuid) ledger,(select count(*)::integer from app_private.fn_audit where event_id=${literal(eventId)}::uuid) audit_count`))[0];
  }
  try {
    const health = await admin.context.request.get(`${base}/api/health`);
    assert(health.ok() && (await health.json()).paymentProvider === 'contract', 'EDGE_EFFECTIVE_CONTRACT_PROVIDER_REQUIRED');
    const copied = await command(admin, 'test.copy', { slug });
    eventId = copied.value.result.eventId;
    assert(UUID.test(eventId) && eventId !== parentEventId, 'EDGE_FRESH_SIBLING_REQUIRED');
    await select(admin);
    await command(admin, 'test.seed');
    await clock('2027-10-30T15:05:00Z');
    runId = (await state(admin)).event.runId;
    assert(UUID.test(runId), 'EDGE_RUN_REQUIRED');
    detail.eventId = eventId; detail.runId = runId;
    const inviteResponse = await admin.context.request.post(`${base}/api/frightnight/edition/invite`, { headers: { Origin: base } });
    assert(inviteResponse.ok(), 'EDGE_EDITION_INVITATION_FAILED');
    const invitation = new URLSearchParams(new URL((await inviteResponse.json()).data.url).hash.slice(1)).get('testinvite');
    assert(invitation, 'EDGE_FRAGMENT_INVITATION_REQUIRED');
    for (const person of [a, b, resident, support]) {
      const entry = await person.context.request.post(`${base}/api/frightnight/edition`, { headers: { Origin: base }, data: { invitation, consent: true } });
      assert(entry.ok(), 'EDGE_EXPLICIT_EDITION_ENTRY_FAILED');
    }
    // Tariff editing uses the real regie form and authoritative server bounds.
    // Restore this sibling's original tariff before creating any test quotes.
    const originalPrice = (await state(admin)).event.priceCents;
    const regiePage = await pageFor(admin, '/avondregie');
    await regiePage.getByRole('button', { name: 'instellingen', exact: true }).click();
    const priceInput = regiePage.getByLabel('Prijs per persoon in euro', { exact: true });
    async function sales({ open = true, routes = ['lantern', 'roots'], minutes = 15 } = {}) {
      const panel = regiePage.getByRole('region', { name: 'Verkoop en verwachte startblokken', exact: true });
      await panel.getByLabel('Verkoop ingeschakeld', { exact: true }).setChecked(open);
      await panel.getByLabel('Lantaarnentocht beschikbaar voor nieuwe verkoop', { exact: true }).setChecked(routes.includes('lantern'));
      await panel.getByLabel('Worteltocht beschikbaar voor nieuwe verkoop', { exact: true }).setChecked(routes.includes('roots'));
      await panel.getByLabel('Verkoop sluiten op (Europe/Amsterdam, optioneel)', { exact: true }).fill('');
      await panel.getByRole('combobox', { name: /^Afstand tussen verwachte startblokken/ }).selectOption(String(minutes));
      const result = await browserCommand(regiePage, 'admin.settings', () => panel.getByRole('button', { name: 'Verkoopinstellingen bewaren', exact: true }).click());
      assert(result.response.ok(), 'EDGE_SALES_UI_SAVE_FAILED');
    }

    for (const [input, status, expectedPrice] of [['0', 409, originalPrice], ['0,01', 200, 1], ['1000,00', 200, 100000], ['1000,01', 409, 100000]]) {
      await priceInput.fill(input);
      const outcome = await browserCommand(regiePage, 'admin.settings', () => regiePage.getByRole('button', { name: 'Tarief serverzijdig bewaren', exact: true }).click());
      assert(outcome.response.status() === status && (await state(admin)).event.priceCents === expectedPrice, 'EDGE_TARIFF_BOUND_OR_PRESERVATION_FAILED');
      if (status === 409) {
        const body = await outcome.response.json();
        assert(body.error?.code === 'INVALID_PRICE' && /0,01|1.000/.test(body.error.message), 'EDGE_TARIFF_BOUND_MESSAGE_MISSING');
      }
    }
    await screen(regiePage, 'hosted-edge-tariff-bounds');
    await priceInput.fill((originalPrice / 100).toFixed(2).replace('.', ','));
    const restoredPrice = await browserCommand(regiePage, 'admin.settings', () => regiePage.getByRole('button', { name: 'Tarief serverzijdig bewaren', exact: true }).click());
    assert(restoredPrice.response.ok() && (await state(admin)).event.priceCents === originalPrice, 'EDGE_TARIFF_NOT_RESTORED');
    pass('PRICE-BOUNDS', 'real regie form accepts one cent and1000euros; zero/above maximum preserve prior tariff with explicit server error');
    const registration = label => ({ label, routeType: 'lantern', adults: 1, children: 1, maxIntensity: 2, avoidSmoke: false, avoidStrobes: false, stepFree: false, startSlot: '2027-10-30T15:00:00Z', consent: true, termsVersion: '2027-test-v1' });
    const invalidPage = await pageFor(a);
    await sales({ open: false });
    const noSale = await reject(a, 'registration.save', registration('Gesloten verkoop test'), [409]);
    assert(noSale.error.code === 'SALES_CLOSED' && !(await state(a)).registration && !(await state(admin)).event.closed, 'EDGE_SALES_CLOSE_GRANTED_REGISTRATION_OR_CLOSED_EVENT');
    await reload(invalidPage);
    assert(await invalidPage.getByRole('button', { name: 'Inschrijving en serverprijs opvragen', exact: true }).isDisabled(), 'EDGE_SALES_CLOSED_SIGNUP_BUTTON_ENABLED');
    await sales({ routes: ['roots'] });
    const noRoute = await reject(a, 'registration.save', registration('Gesloten tocht test'), [409]);
    assert(noRoute.error.code === 'ROUTE_SALES_CLOSED' && !(await state(a)).registration, 'EDGE_DISABLED_ROUTE_ACCEPTED_NEW_SIGNUP');
    await sales(); await reload(invalidPage);
    pass('SALES-POLICY', 'actual regie sales form independently closes sales and disables one route; new signup stays absent while event remains open');

    await invalidPage.getByLabel('Naam van je gezelschap', { exact: true }).fill('Pakketproef zonder geldige personen');
    await invalidPage.getByLabel('Volwassenen', { exact: true }).fill('0');
    assert(!await invalidPage.getByLabel('Volwassenen', { exact: true }).evaluate(input => input.checkValidity()), 'INS02_NATIVE_PERSON_VALIDATION_FAILED');
    for (const payload of [{ ...registration('Ongeldig nul'), adults: 0, children: 0 }, { ...registration('Ongeldig te groot'), adults: 20, children: 20 }, { ...registration('Ongeldig blok'), startSlot: '2027-10-30T11:00:00Z' }]) await reject(a, 'registration.save', payload);
    assert(!(await state(a)).registration, 'INS02_INVALID_REGISTRATION_PERSISTED');
    pass('INS-02', 'zero, oversized and unavailable-block API rejection; native person validity', { remaining: 'Invalid Auth-email submission is intentionally not sent.' });
    for (const [person, label] of [[a, 'Pakketproef gezin A'], [b, 'Pakketproef gezin B']]) {
      await command(person, 'registration.save', registration(label));
      await fixture(`update app_private.fn_registrations set synthetic=true where event_id=eid and run_id=own_run and owner_id=${literal(person.id)}::uuid;`);
    }
    await sales({ routes: ['roots'] });
    const noCheckout = await reject(a, 'payment.checkout', {}, [409]);
    const noOrders = await sql(`select count(*)::integer n from app_private.fn_orders where event_id=${literal(eventId)}::uuid`);
    assert(noCheckout.error.code === 'ROUTE_SALES_CLOSED' && Number(noOrders[0].n) === 0, 'EDGE_DISABLED_ROUTE_CHECKOUT_CREATED_ORDER');
    await sales();
    await invalidPage.goto(`${base}/nachtpas?betaling=terug&payment=success&status=paid`, { waitUntil: 'domcontentloaded' });
    await invalidPage.locator('.fn-environment-nav').waitFor();
    let sa = await state(a);
    await reject(a, 'journey.start', { code: await code(), expectedVersion: sa.journey.version }, [403]);
    const unpaidAfter = await state(a);
    assert(unpaidAfter.registration.paymentStatus === 'unpaid' && !unpaidAfter.current && unpaidAfter.journey.state === 'ready', 'INS04_RETURN_URL_GRANTED_PAYMENT_OR_ROUTE');
    pass('INS-04', 'forged successful return leaves registration unpaid and start unauthorized');
    await command(admin, 'admin.startslot.save', { startsAt: registration('').startSlot, capacity: 2 });
    const raced = await Promise.all([command(a, 'payment.checkout', {}, true), command(b, 'payment.checkout', {}, true)]);
    detail.startSlotRace = raced.map(result => ({ status: result.status, code: result.error?.code, simulated: result.value?.result?.simulated }));
    assert(raced.filter(result => result.status === 200 && result.value.result.simulated === true).length === 1 && raced.filter(result => [409, 422].includes(result.status) && result.error?.code === 'START_SLOT_FULL').length === 1, 'INS07_LAST_SLOT_RACE_FAILED');
    const winner = raced[0].status === 200 ? a : b;
    const loser = winner === a ? b : a;
    const held = await sql(`select coalesce(sum(r.adults+r.children),0)::integer persons from app_private.fn_orders o join app_private.fn_registrations r on r.event_id=o.event_id and r.id=o.registration_id where o.event_id=${literal(eventId)}::uuid and o.status='open' and o.hold_until>now()`);
    assert(Number(held[0].persons) === 2, 'INS07_HOLD_OVERBOOKED');
    await fixture(`update app_private.fn_orders set hold_until=now()-interval '1 second' where event_id=eid and registration_id in(select id from app_private.fn_registrations where event_id=eid and run_id=own_run and synthetic and owner_id=${literal(winner.id)}::uuid) and status='open';`);
    const retried = await command(loser, 'payment.checkout');
    assert(retried.value.result.simulated === true && (await state(loser)).registration.paymentStatus !== 'paid', 'INS07_EXPIRED_HOLD_NOT_RELEASED');
    await command(admin, 'admin.startslot.save', { startsAt: registration('').startSlot, capacity: 50 });
    pass('INS-07', 'two actual checkout requests race last start places; expired own hold frees capacity', { remaining: 'Contract adapter only; alternate-block proposal UI is not asserted.', provider: 'contract', confirmedPayments: 0 });
    // Preserve a real open quote/hold and a separately explicit synthetic paid
    // registration on old :15/:45 blocks when the grid becomes ten minutes.
    for (const [person, slot] of [[winner, '2027-10-30T15:45:00Z'], [loser, '2027-10-30T15:15:00Z']]) {
      const own = await state(person);
      await command(person, 'registration.save', { ...registration(own.registration.label), startSlot: slot, expectedVersion: own.registration.version });
    }
    await command(loser, 'payment.checkout');
    await fixture(`update app_private.fn_registrations set status='active',payment_status='paid',version=version+1 where event_id=eid and run_id=own_run and synthetic and owner_id=${literal(winner.id)}::uuid;`);
    const beforeGrid = await financial();
    const paidBeforeGrid = (await state(winner)).registration;
    const holdBeforeGrid = (await state(loser)).registration;
    await sales({ minutes: 10 });
    const paidAfterGrid = await state(winner);
    const holdAfterGrid = await state(loser);
    for (const [snapshot, previous] of [[paidAfterGrid, paidBeforeGrid], [holdAfterGrid, holdBeforeGrid]]) {
      const oldSlot = snapshot.startSlots.find(slot => Date.parse(slot.startsAt) === Date.parse(previous.startSlot));
      assert(snapshot.registration.startSlot === previous.startSlot && snapshot.registration.paymentStatus === previous.paymentStatus && snapshot.registration.amountCents === previous.amountCents && oldSlot && oldSlot.enabled === false && oldSlot.historical === true, 'EDGE_BLOCK_CHANGE_LOST_OLD_PAID_OR_HOLD_PLACE');
    }
    const afterGrid = await financial();
    assert(beforeGrid.orders === afterGrid.orders && beforeGrid.ledger === afterGrid.ledger && paidAfterGrid.event.startBlockMinutes === 10, 'EDGE_BLOCK_CHANGE_MUTATED_FINANCIAL_QUOTE');
    await sales({ minutes: 15 });
    pass('SALES-BLOCKS', 'actual fifteen→ten minute setting preserves historical paid fixture and open contract hold on old blocks and every quoted financial row', { confirmedProviderPayments: 0, remaining: 'Paid status is an explicit scoped SQL route fixture; external payment confirmation is not claimed.' });

    // Explicit synthetic route fixtures; this is not a provider confirmation.
    await fixture(`update app_private.fn_orders set hold_until=now()-interval '1 second' where event_id=eid;
      update app_private.fn_registrations set status='active',payment_status='paid',version=version+1 where event_id=eid and run_id=own_run and synthetic and owner_id in(${literal(a.id)}::uuid,${literal(b.id)}::uuid);
      update app_private.fn_zones set capacity=20 where event_id=eid and run_id=own_run and synthetic;
      insert into app_private.fn_zones(event_id,owner_id,name,address,type,intensity,capacity,status,review_status,opens_at,closes_at,description,synthetic,run_id,token_hash)
      select eid,${literal(resident.id)}::uuid,'Synthetische pakketzone '||i,'Geen fysiek testadres '||i,'candy',0,20,'open','approved','2027-10-30T15:00:00Z','2027-10-30T19:00:00Z','Uitsluitend synthetische routeproef; geen echte straataansluiting.',true,own_run,extensions.digest(eid::text||':edge:'||i,'sha256') from generate_series(1,5)i;`);
    await command(admin, 'test.walk.fixture');
    // A help request belongs to its submitter. Staff identity is exposed only
    // to authorized regie, while the participant sees assignment as a boolean.
    {
    const helpText = `Afzonderlijke hulpacceptatie ${runId}`;
    const help = await command(a, 'help.submit', { category: 'route', text: helpText });
    const incidentId = help.value.result.incidentId;
    let ownIncident = (await state(a)).ownIncidents.find(item => item.id === incidentId);
    assert(UUID.test(incidentId) && ownIncident?.version === 1 && ownIncident.assigned === false, 'EDGE_HELP_INITIAL_STATE_INVALID');
    const staffChoices = (await state(admin)).incidentStaffChoices;
    assert(staffChoices.some(person => person.id === admin.id) && staffChoices.every(person => !person.label.includes('@')), 'EDGE_HELP_CONFIRMED_STAFF_CHOICES_INVALID');
    await reject(a, 'help.assign', { incidentId, expectedVersion: ownIncident.version, assignedTo: admin.id }, [403]);
    await reject(b, 'help.reply', { incidentId, expectedVersion: ownIncident.version, text: 'Onbevoegd antwoord' }, [403]);
    await reject(admin, 'help.assign', { incidentId, expectedVersion: ownIncident.version, assignedTo: b.id }, [403]);
    assert((await state(a)).ownIncidents.find(item => item.id === incidentId).version === ownIncident.version, 'EDGE_HELP_REJECTION_MUTATED_VERSION');
    await regiePage.getByRole('button', { name: 'meldingen', exact: true }).click();
    await regiePage.getByRole('textbox', { name: 'Zoek in alle hulpvragen', exact: true }).fill(helpText);
    const helpRow = regiePage.getByRole('row').filter({ hasText: helpText });
    await helpRow.waitFor();
    async function openHelpActions() {
      const current = (await state(a)).ownIncidents.find(item => item.id === incidentId);
      const details = helpRow.locator('details').filter({ hasText: `Versie ${current.version}.` });
      await details.waitFor();
      if (!await details.evaluate(element => element.open)) await details.locator('summary').click();
    }
    await openHelpActions();
    await helpRow.getByRole('combobox', { name: /^Behandelaar/ }).selectOption(admin.id);
    const assigned = await browserCommand(regiePage, 'help.assign', () => helpRow.getByRole('button', { name: 'Toewijzing bewaren', exact: true }).click());
    assert(assigned.response.ok() && assigned.command.payload.expectedVersion === ownIncident.version, 'EDGE_HELP_ASSIGNMENT_UI_FAILED');
    const firstVersion = ownIncident.version;
    ownIncident = (await state(a)).ownIncidents.find(item => item.id === incidentId);
    assert(ownIncident.assigned && ownIncident.version === firstVersion + 1 && !('assignedTo' in ownIncident), 'EDGE_HELP_ASSIGNMENT_OWNER_PRIVACY_FAILED');
    await reject(admin, 'help.assign', { incidentId, expectedVersion: firstVersion, assignedTo: null }, [409]);
    const privateHelp = await state(a);
    assert(!privateHelp.incidentStaffChoices && !(await state(b)).ownIncidents.some(item => item.id === incidentId), 'EDGE_HELP_CROSS_ACTOR_OR_STAFF_PRIVACY_FAILED');
    const helpPage = await pageFor(a);
    await helpPage.getByRole('button', { name: 'Hulp', exact: true }).click();
    const ownHelpRow = helpPage.locator('article').filter({ hasText: helpText });
    await ownHelpRow.getByText('Toegewezen', { exact: true }).waitFor();
    assert(!(await ownHelpRow.innerText()).includes(admin.id), 'EDGE_HELP_STAFF_UUID_RENDERED_TO_PARTICIPANT');
    await screen(helpPage, 'hosted-edge-help-assigned');
    await openHelpActions();
    await helpRow.getByRole('combobox', { name: /^Behandelaar/ }).selectOption('');
    const cleared = await browserCommand(regiePage, 'help.assign', () => helpRow.getByRole('button', { name: 'Toewijzing bewaren', exact: true }).click());
    assert(cleared.response.ok() && !(await state(a)).ownIncidents.find(item => item.id === incidentId).assigned, 'EDGE_HELP_UNASSIGNMENT_FAILED');
    await reload(helpPage); await helpPage.getByRole('button', { name: 'Hulp', exact: true }).click();
    await ownHelpRow.getByText('In wachtrij', { exact: true }).waitFor();
    await openHelpActions();
    const replyText = 'Het vaste hulppunt is op het Duinpad. Dit is uitsluitend een synthetische proef.';
    await helpRow.getByLabel('Antwoord', { exact: true }).fill(replyText);
    const reply = await browserCommand(regiePage, 'help.reply', () => helpRow.getByRole('button', { name: 'Antwoord bewaren en melden', exact: true }).click());
    assert(reply.response.ok() && Number.isInteger(reply.command.payload.expectedVersion), 'EDGE_HELP_VERSIONED_REPLY_UI_FAILED');
    await openHelpActions();
    const resolved = await browserCommand(regiePage, 'admin.incident.resolve', () => helpRow.getByRole('button', { name: 'Hulpvraag afhandelen', exact: true }).click());
    assert(resolved.response.ok() && Number.isInteger(resolved.command.payload.expectedVersion), 'EDGE_HELP_VERSIONED_RESOLVE_UI_FAILED');
    await reload(helpPage); await helpPage.getByRole('button', { name: 'Hulp', exact: true }).click();
    await ownHelpRow.getByText('Afgehandeld', { exact: true }).waitFor();
    assert((await ownHelpRow.innerText()).includes(replyText) && (await state(a)).notifications.some(item => item.message === replyText), 'EDGE_HELP_REPLY_NOT_DURABLE');
    await screen(regiePage, 'hosted-edge-help-management');
    pass('HELP-ASSIGNMENT', 'real regie assignment, unassignment, versioned reply and resolve persist; unauthorized actor/target and stale version fail; owner receives status and durable answer without staff identity');
    }
    const startCode = await code();
    await clock('2027-10-30T14:59:59Z');
    sa = await state(a);
    await reject(a, 'journey.start', { code: startCode, expectedVersion: sa.journey.version });
    await clock('2027-10-30T15:05:00Z');
    let pa = await pageFor(a);
    await pa.getByRole('button', { name: 'Nachtpas', exact: true }).click();
    const awardsBefore = (await state(a)).progress.awards.length;
    await pa.getByRole('button', { name: 'Ontdek het proeflicht', exact: true }).click();
    assert(await pa.getByLabel('Proeflicht, stap 1 van 3').isVisible(), 'BAK01_REHEARSAL_DID_NOT_REACT');
    assert(await pa.getByRole('button', { name: 'Geef het Duinlicht terug', exact: true }).isDisabled(), 'BAK01_PRE_FINALE_BUTTON_ENABLED');
    await reject(a, 'beacon.complete', {});
    assert((await state(a)).progress.awards.length === awardsBefore, 'BAK01_PRE_FINALE_AWARD_PERSISTED');
    await screen(pa, 'hosted-edge-rehearsal');
    pass('BAK-01', 'digital rehearsal reacts; hidden finale command rejected without durable award', { remaining: 'Physical locally controlled beacon is not exercised.' });
    for (const [operation, payload] of [['quest.answer', { questId: randomUUID(), answer: 'gemanipuleerd' }], ['award.grant', { awardId: randomUUID(), sparks: 100000 }], ['beacon.complete', { completed: true, paid: true }]]) await reject(a, operation, payload);
    assert((await state(a)).progress.awards.length === awardsBefore, 'KID03_CLIENT_MANIPULATION_GRANTED_AWARDS');
    pass('KID-03', 'unknown quest, invented award command and hidden finale manipulation grant no awards');
    const zones = (await state(admin)).zones;
    const finale = zones.find(zone => zone.type === 'finale');
    const ordinary = zones.find(zone => zone.type === 'candy');
    assert(finale && ordinary, 'EDGE_ROUTE_FIXTURES_REQUIRED');
    await fixture(`update app_private.fn_zones set status='closed' where event_id=eid and run_id=own_run and synthetic and type<>'finale';
      update app_private.fn_zones set status='open',closes_at='2027-10-30T15:06:00Z' where event_id=eid and run_id=own_run and id=${literal(ordinary.id)}::uuid;`);
    sa = await state(a);
    await command(a, 'journey.start', { code: startCode, expectedVersion: sa.journey.version });
    sa = await state(a);
    assert(sa.current?.zone.type === 'finale' && !sa.progress.visits.length, 'ROU08_TOO_LATE_ZONE_ASSIGNED');
    const decision = await sql(`select details->>'reason' reason from app_private.fn_audit where event_id=${literal(eventId)}::uuid and action='route.decision' and details->>'partyId'=${literal(sa.journey.id)} order by id desc limit 1`);
    assert(decision[0]?.reason === 'finale-return' && /Duinpad|finale/.test(sa.current.reason), 'ROU08_FALLBACK_REASON_MISSING');
    pass('ROU-08', 'only ordinary candidate closes before arrival plus visit margin; server selects explained finale', { remaining: 'Synthetic walk durations; decision trace records fallback rather than an individual exclusion code.' });
    await fixture(`update app_private.fn_zones set status='open',opens_at='2027-10-30T15:00:00Z',closes_at='2027-10-30T19:00:00Z' where event_id=eid and run_id=own_run and synthetic;`);
    await command(a, 'journey.resume', { expectedVersion: sa.journey.version });
    await settings({ qrRequired: false });
    await reload(pa);
    assert(await pa.getByRole('button', { name: 'Bezoek afronden', exact: true }).isVisible(), 'QR11_RELEASE_BUTTON_MISSING');
    sa = await state(a);
    assert(sa.current?.zone.type !== 'finale', 'QR11_NORMAL_DESTINATION_REQUIRED');
    const released = await browserCommand(pa, 'journey.complete', () => pa.getByRole('button', { name: 'Bezoek afronden', exact: true }).click());
    assert(released.response.ok(), 'QR11_RELEASED_VISIT_FAILED');
    let next = await state(a);
    assert(next.progress.visits.length === sa.progress.visits.length + 1 && next.current?.id !== sa.current.id, 'QR11_RELEASED_VISIT_NOT_ATOMIC');
    await settings({ qrRequired: true });
    await reload(pa);
    assert(await pa.getByRole('button', { name: 'Scan bij deze bestemming', exact: true }).isVisible(), 'QR11_REQUIRED_POLICY_NOT_RESTORED');
    await reject(a, 'journey.complete', { destinationId: next.current.id, expectedVersion: next.journey.version });
    await screen(pa, 'hosted-edge-qr-policy-restored');
    pass('QR-11', 'QR release and restore synchronize actual visit button, server validation and browser reload', { remaining: 'VPS process restart is not performed.' });
    // ROU07 uses the actual owner form. Known application groups overlap the
    // app reservation rather than creating another group-sized capacity claim.
    next = await state(a);
    const observedDestination = next.current;
    await fixture(`update app_private.fn_zones set owner_id=${literal(resident.id)}::uuid where event_id=eid and run_id=own_run and synthetic and id=${literal(observedDestination.zoneId)}::uuid;`);
    const pr = await pageFor(resident, '/mijn-zone');
    const occupancyPanel = pr.locator(`[aria-labelledby="occupancy-${observedDestination.zoneId}"]`);
    const ownedBefore = (await state(resident)).ownZones.find(zone => zone.id === observedDestination.zoneId);
    assert(ownedBefore.occupancy.appPersons === 2 && ownedBefore.occupancy.effectivePersons === 2 && observedDestination.visitReference, 'ROU07_BASELINE_APP_CLAIM_REQUIRED');
    await occupancyPanel.locator(`input[name=observedDestinationIds][value="${observedDestination.id}"]`).check();
    await occupancyPanel.getByLabel('Extra personen buiten deze bekende appgroepen', { exact: true }).fill('1');
    await occupancyPanel.getByLabel('Ik heb dit ter plaatse gecontroleerd. Extra personen zijn nergens anders in deze waarneming meegeteld.', { exact: true }).check();
    const observed = await browserCommand(pr, 'zone.occupancy', () => occupancyPanel.getByRole('button', { name: 'Bezetting bevestigen', exact: true }).click());
    assert(observed.response.ok(), 'ROU07_OWNER_FORM_FAILED');
    let owned = (await state(resident)).ownZones.find(zone => zone.id === observedDestination.zoneId);
    assert(owned.occupancy.appPersons === 2 && owned.occupancy.observedKnownPersons === 2 && owned.occupancy.overlapPersons === 2 && owned.occupancy.extraPersons === 1 && owned.occupancy.effectivePersons === 3 && owned.occupancy.fresh, 'ROU07_KNOWN_GROUP_DOUBLE_COUNTED');
    assert(!Object.hasOwn((await state(a)).current.zone.occupancy, 'candidates'), 'ROU07_PARTICIPANT_SEES_OTHER_GROUP_IDENTIFIERS');
    await reject(a, 'zone.occupancy', { zoneId: owned.id, expectedVersion: owned.version, observedDestinationIds: [], extraPersons: 0, confirmedUncounted: true }, [403]);
    await reject(resident, 'zone.occupancy', { zoneId: owned.id, expectedVersion: ownedBefore.version, observedDestinationIds: [], extraPersons: 0, confirmedUncounted: true }, [409]);
    await reject(resident, 'zone.occupancy', { zoneId: owned.id, expectedVersion: owned.version, observedDestinationIds: [observedDestination.id, observedDestination.id], extraPersons: 0, confirmedUncounted: true });
    await screen(pr, 'hosted-edge-owner-occupancy');
    await fixture(`update app_private.fn_zones set observed_at=now()-interval '6 minutes',observation_expires_at=now()-interval '1 minute' where event_id=eid and run_id=own_run and synthetic and id=${literal(owned.id)}::uuid;`);
    owned = (await state(resident)).ownZones.find(zone => zone.id === owned.id);
    assert(owned.occupancy.observationStale && owned.occupancy.admissionBlocked && owned.occupancy.available === 0 && owned.occupancy.effectivePersons === 3, 'ROU07_STALE_OBSERVATION_SILENTLY_RELEASED');
    next = await state(a);
    await command(a, 'journey.resume', { expectedVersion: next.journey.version });
    assert((await state(a)).current?.zoneId !== owned.id, 'ROU07_STALE_ZONE_ADMITTED_NEW_DESTINATION');
    await reload(pr);
    const clearing = pr.locator(`[aria-labelledby="occupancy-${owned.id}"]`);
    await clearing.getByLabel('Ik zie geen bezoekers meer: bevestig een lege waarneming en geef mijn eerdere waarneming vrij.', { exact: true }).check();
    await clearing.getByLabel('Ik heb dit ter plaatse gecontroleerd. Extra personen zijn nergens anders in deze waarneming meegeteld.', { exact: true }).check();
    const cleared = await browserCommand(pr, 'zone.occupancy', () => clearing.getByRole('button', { name: 'Lege waarneming bevestigen', exact: true }).click());
    assert(cleared.response.ok(), 'ROU07_EMPTY_OBSERVATION_CLEAR_FAILED');
    owned = (await state(resident)).ownZones.find(zone => zone.id === owned.id);
    assert(owned.occupancy.effectivePersons === 0 && owned.occupancy.extraPersons === 0 && !owned.occupancy.observationStale && !owned.occupancy.admissionBlocked, 'ROU07_FRESH_EMPTY_OBSERVATION_DID_NOT_RELEASE_OLD_LOAD');
    pass('ROU-07', 'actual resident form unions known app group once, adds only extras, retains stale load and requires explicit empty confirmation', { appPersons: 2, observedKnownPersons: 2, overlapPersons: 2, extraPersons: 1, effectivePersons: 3, staleAgeFixture: 'exact own synthetic zone only; six real-clock minutes', remaining: 'No elapsed-time/physical head-count claim.' });
    next = await state(a);
    // An actor can legitimately be both participant and house owner. The
    // richer live projection must never expand the disk-cache whitelist.
    next = await state(a);
    await fixture(`update app_private.fn_zones set owner_id=${literal(a.id)}::uuid where event_id=eid and run_id=own_run and synthetic and id=${literal(next.current.zoneId)}::uuid;`);
    const dual = await state(a);
    assert(Array.isArray(dual.current.zone.occupancy.candidates) && dual.ownZones.some(zone => zone.id === dual.current.zoneId), 'EDGE_DUAL_ROLE_LIVE_PROJECTION_REQUIRED');
    await reload(pa);
    const cache = await pa.evaluate(({ actor, selectedSlug }) => {
      const value = JSON.parse(localStorage.getItem(`duindorp-private-group:frightnight-v1:${actor}:${selectedSlug}`) ?? 'null');
      return value?.snapshot ? { present: true, ownZones: value.snapshot.ownZones.length, currentId: value.snapshot.current?.id, reference: value.snapshot.current?.visitReference, currentOccupancy: Object.hasOwn(value.snapshot.current?.zone ?? {}, 'occupancy'), journeyOccupancy: Object.hasOwn(value.snapshot.journey?.current?.zone ?? {}, 'occupancy') } : { present: false };
    }, { actor: a.id, selectedSlug: slug });
    assert(cache.present && cache.ownZones === 0 && cache.currentId === dual.current.id && cache.reference === dual.current.visitReference && !cache.currentOccupancy && !cache.journeyOccupancy, 'EDGE_DUAL_ROLE_OWNER_FIELDS_PERSISTED_OFFLINE');
    pass('DUAL-ROLE-OFFLINE', 'actual participant/owner live projection includes own candidates; both disk-cache destination projections omit owner occupancy');
    next = await state(a);
    // A second real adult operates the existing registration, then loses both
    // new-command and old-receipt access after explicit owner revocation.
    const adultInvite = await command(a, 'registration.invite');
    await command(support, 'registration.accept', { token: adultInvite.value.result.token, consent: true });
    const ps = await pageFor(support);
    const shared = await state(support);
    assert(shared.registration.id === next.registration.id && shared.journey.id === next.journey.id, 'SEC06_SECOND_ADULT_SPLIT_REGISTRATION');
    const adultScan = await scan(ps, await code(shared.current.zoneId));
    assert(adultScan.response.ok(), 'SEC06_AUTHORIZED_ADULT_SCAN_FAILED');
    await command(a, 'registration.revoke', { userId: support.id });
    const revoked = await state(support);
    assert(!revoked.registration && !revoked.current && !revoked.progress.visits.length, 'SEC06_REVOKED_PRIVATE_SNAPSHOT_RETAINED');
    await reject(support, 'journey.resume', { expectedVersion: shared.journey.version }, [403]);
    await reject(support, adultScan.command.operation, adultScan.command.payload, [403], adultScan.command.commandId);
    const ownRegistrations = await sql(`select count(*)::integer n from app_private.fn_registrations where event_id=${literal(eventId)}::uuid and owner_id in(${literal(a.id)}::uuid,${literal(support.id)}::uuid)`);
    assert(Number(ownRegistrations[0].n) === 1, 'SEC06_ADULT_CREATED_SECOND_REGISTRATION');
    pass('SEC-06', 'second adult scans same registration; revoke denies new commands and private receipt replay', { confirmedPayments: 0, note: 'Existing synthetic quote rows are unchanged; no second adult checkout.' });
    // Browser offline is real setOffline(), distinct from an injected HTTP503.
    const secondA = await copyContext(a);
    await reload(pa);
    sa = await state(a);
    const beforeOffline = sa.progress.visits.length;
    await a.context.setOffline(true);
    await beginScan(pa, await code(sa.current.zoneId));
    await pa.getByRole('button', { name: 'Controleer code', exact: true }).click();
    await pa.getByText(/Bezoek wacht op verbinding\./).first().waitFor();
    const queued = await pending(pa);
    assert(UUID.test(queued.id) && queued.operation === 'journey.complete' && (await state(secondA)).progress.visits.length === beforeOffline, 'EDGE_OFFLINE_FALSE_CONFIRMATION');
    await pa.getByRole('button', { name: 'Scanner sluiten', exact: true }).click();
    await a.context.setOffline(false);
    await pa.getByText('Netwerk beschikbaar', { exact: true }).waitFor();
    const retry = await browserCommand(pa, 'journey.complete', () => pa.getByRole('button', { name: 'Veilig opnieuw proberen', exact: true }).click());
    assert(retry.response.ok() && retry.command.commandId === queued.id, 'EDGE_OFFLINE_CHANGED_COMMAND_ID');
    const confirmed = await state(a);
    assert(confirmed.progress.visits.length === beforeOffline + 1, 'EDGE_OFFLINE_RECONNECT_VISIT_MISSING');
    await command(a, retry.command.operation, retry.command.payload, false, retry.command.commandId);
    assert((await state(a)).progress.sparks === confirmed.progress.sparks, 'EDGE_OFFLINE_REPLAY_DUPLICATED_REWARD');
    await reload(pa); sa = await state(a);
    const staleCode = await code(sa.current.zoneId);
    await a.context.setOffline(true);
    await beginScan(pa, staleCode);
    await pa.getByRole('button', { name: 'Controleer code', exact: true }).click();
    await pa.getByText(/Bezoek wacht op verbinding\./).first().waitFor();
    await command(secondA, 'journey.pause', { expectedVersion: sa.journey.version });
    await pa.getByRole('button', { name: 'Scanner sluiten', exact: true }).click();
    await a.context.setOffline(false);
    await pa.getByText('Netwerk beschikbaar', { exact: true }).waitFor();
    const conflict = await browserCommand(pa, 'journey.complete', () => pa.getByRole('button', { name: 'Veilig opnieuw proberen', exact: true }).click());
    assert(conflict.response.status() === 409 && (await state(a)).progress.visits.length === sa.progress.visits.length, 'EDGE_OFFLINE_STALE_ROUTE_ACCEPTED');
    await screen(pa, 'hosted-edge-offline-conflict');
    sa = await state(a); await command(a, 'journey.resume', { expectedVersion: sa.journey.version });
    pass('OFFLINE-RECOVERY', 'real browser offline queues unconfirmed scan; reconnect reuses ID once and stale second-tab route returns409');
    // An actual cookie change between two existing Auth sessions must erase A's
    // cache and content. This creates no sessions, users or authorization roles.
    const identity = await copyContext(a);
    const pi = await pageFor(identity);
    await pi.waitForFunction(actor => sessionStorage.getItem('frightnight-active-actor') === actor, a.id);
    await identity.context.clearCookies(); await identity.context.addCookies(await b.context.cookies());
    try { await reload(pi); } catch (error) { if (!String(error).includes('ERR_ABORTED')) throw error; await pi.locator('.fn-environment-nav').waitFor(); }
    await pi.waitForFunction(actor => sessionStorage.getItem('frightnight-active-actor') === actor, b.id);
    assert((await state(identity)).actor.id === b.id, 'EDGE_IDENTITY_COOKIE_SWITCH_FAILED');
    const identityClean = await pi.evaluate(actor => !Object.keys(localStorage).some(key => key.startsWith('duindorp-private-group:') && key.includes(actor)), a.id);
    assert(identityClean && !await pi.getByRole('heading', { name: 'Pakketproef gezin A', exact: true }).count(), 'EDGE_OLD_IDENTITY_PRIVATE_DATA_RETAINED');
    await pi.goto(`${base}/`, { waitUntil: 'domcontentloaded' }); await pi.goBack({ waitUntil: 'domcontentloaded' }); await pi.locator('.fn-environment-nav').waitFor();
    assert((await state(identity)).actor.id === b.id, 'EDGE_BACK_NAVIGATION_RESTORED_OLD_IDENTITY');
    pass('IDENTITY-ISOLATION', 'actual A→B Auth cookie switch and back navigation remove old private cache and identity');
    sa = await state(a);
    assert(sa.current?.zone.type !== 'finale', 'ROU09_ORDINARY_DESTINATION_REQUIRED');
    const skipped = sa.current;
    const skippedCode = await code(skipped.zoneId);
    await command(a, 'journey.skip', { destinationId: skipped.id, expectedVersion: sa.journey.version });
    next = await state(a);
    assert(next.current?.zoneId !== skipped.zoneId, 'ROU09_SKIPPED_ZONE_REASSIGNED');
    await reject(a, 'journey.complete', { destinationId: skipped.id, expectedVersion: next.journey.version, code: skippedCode }, [409]);
    if (next.current) await reject(a, 'journey.complete', { destinationId: next.current.id, expectedVersion: next.journey.version, code: skippedCode });
    assert((await state(a)).progress.sparks === next.progress.sparks && (await state(a)).progress.visits.length === next.progress.visits.length, 'ROU09_OLD_QR_GRANTED_AWARD');
    pass('ROU-09', 'skip ordinary zone; stale destination and old QR give no award or immediate reassignment');
    sa = await state(a);
    const expired = sa.current;
    await clock(new Date(new Date(expired.leaseUntil).getTime() + 1000).toISOString());
    await reject(a, 'journey.complete', { destinationId: expired.id, expectedVersion: sa.journey.version, code: await code(expired.zoneId) }, [409]);
    assert((await state(a)).current?.id === expired.id, 'ROU06_SNAPSHOT_SILENTLY_DROPPED_CLAIM');
    await reload(pa);
    await pa.getByRole('button', { name: 'Hervatten en bestemming controleren', exact: true }).waitFor();
    assert(!await pa.getByRole('button', { name: 'Scan bij deze bestemming', exact: true }).count() && await pa.getByRole('button', { name: 'Deze zone overslaan', exact: true }).isDisabled(), 'ROU06_EXPIRED_DESTINATION_STILL_ACTIONABLE');
    const protectedCleanup = await reject(admin, 'test.cleanup', { confirmation: slug, runId }, [403]);
    assert(protectedCleanup.status === 403, 'RET02_PROTECTED_EDITION_CLEANUP_ACCEPTED');
    const recovered = await command(admin, 'admin.leases.recover');
    assert(Number(recovered.value.result.recovered) >= 1 && !(await state(a)).current, 'ROU06_EXPIRED_CLAIM_NOT_RELEASED');
    const oldClaim = await sql(`select state from app_private.fn_destinations where event_id=${literal(eventId)}::uuid and id=${literal(expired.id)}::uuid`);
    assert(oldClaim[0]?.state === 'released', 'ROU06_RELEASE_NOT_DURABLE');
    next = await state(a);
    await reject(a, 'journey.complete', { destinationId: expired.id, expectedVersion: sa.journey.version, code: await code(expired.zoneId) }, [409]);
    await reload(pa);
    const leaseResume = await browserCommand(pa, 'journey.resume', () => pa.getByRole('button', { name: 'Hervatten en bestemming controleren', exact: true }).click());
    assert(leaseResume.response.ok() && leaseResume.command.payload.expectedVersion === next.journey.version, 'ROU06_RECOVERY_BUTTON_FAILED');
    assert((await state(a)).current?.id !== expired.id && (await state(a)).event.runId === runId, 'RET02_EXPIRED_RESUME_OR_RETENTION_FAILED');
    pass('ROU-06', 'expired claim remains until explicit recovery, releases capacity and denies stale route version');
    pass('RET-02', 'targeted lease maintenance and protected cleanup denial preserve same test edition/run', { remaining: 'No elapsed-week or external timer-duration claim.' });
    // B has never started. The exact end rejects starting; one minute earlier
    // can promise only the finale instead of a whole infeasible house route.
    await clock('2027-10-30T16:30:00Z');
    let sb = await state(b);
    await reject(b, 'journey.start', { code: startCode, expectedVersion: sb.journey.version });
    assert(!(await state(b)).current && (await state(b)).journey.state === 'ready', 'EDGE_ROUTE_WINDOW_END_GRANTED_START');
    await clock('2027-10-30T16:29:00Z');
    sb = await state(b);
    await command(b, 'journey.start', { code: startCode, expectedVersion: sb.journey.version });
    sb = await state(b);
    assert(sb.current?.zone.type === 'finale' && /Duinpad|finale/.test(sb.current.reason), 'QR04_LATE_START_PROMISED_INFEASIBLE_ROUTE');
    pass('QR-04', 'late initial start gets explained Duinpad finale instead of an infeasible full route', { remaining: 'Only deterministic synthetic walking durations.' });
    async function rejectedJoin(token) {
      const before = await financial();
      const registrationsBefore = await sql(`select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) digest from app_private.fn_registrations r where event_id=${literal(eventId)}::uuid`);
      await reject(b, 'party.join', { token, consent: true });
      const registrationsAfter = await sql(`select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) digest from app_private.fn_registrations r where event_id=${literal(eventId)}::uuid`);
      const after = await financial();
      assert(registrationsBefore[0].digest === registrationsAfter[0].digest && before.orders === after.orders && before.ledger === after.ledger, 'SAM02_REJECTED_JOIN_MUTATED_REGISTRATION_OR_ORDER');
    }
    const invite = await command(a, 'party.invite');
    await fixture(`update app_private.fn_registrations set route_type='roots',start_slot='2027-10-30T16:30:00Z' where event_id=eid and run_id=own_run and synthetic and owner_id=${literal(b.id)}::uuid;`);
    await rejectedJoin(invite.value.result.token);
    await fixture(`update app_private.fn_registrations set route_type='lantern',start_slot='2027-10-30T15:00:00Z' where event_id=eid and run_id=own_run and synthetic and owner_id=${literal(b.id)}::uuid;
      update app_private.fn_invites set expires_at=now()-interval '1 second' where event_id=eid and party_id in(select party_id from app_private.fn_members where event_id=eid and registration_id in(select id from app_private.fn_registrations where event_id=eid and owner_id=${literal(a.id)}::uuid));`);
    await rejectedJoin(invite.value.result.token);
    const large = await command(a, 'party.invite');
    await fixture(`update app_private.fn_events set max_party=3,max_registration_persons=3 where event_id=eid;`);
    await rejectedJoin(large.value.result.token);
    await fixture(`update app_private.fn_events set max_party=20,max_registration_persons=20 where event_id=eid;`);
    pass('SAM-02', 'wrong evening, expired invitation and excessive total group are rejected without registration/order changes');
    const concurrentInvite = await command(a, 'party.invite');
    const joined = await Promise.all([command(b, 'party.join', { token: concurrentInvite.value.result.token, consent: true }), command(a, 'preferences.save', { maxIntensity: 1, avoidSmoke: true, avoidStrobes: true, stepFree: true })]);
    assert(joined.every(result => result.status === 200), 'SAM08_CONCURRENT_COMMAND_FAILED');
    sa = await state(a); sb = await state(b);
    assert(sa.journey.id === sb.journey.id && sa.current?.id === sb.current?.id && sa.journey.party.persons === 4 && sa.journey.party.maxIntensity === 1 && sa.journey.party.avoidSmoke && sa.journey.party.avoidStrobes && sa.journey.party.stepFree, 'SAM08_CURRENT_MEMBER_PREFERENCES_NOT_ATOMIC');
    if (sa.current && sa.current.zone.type !== 'finale') assert((sa.current.zone.type === 'candy' || sa.current.zone.intensity <= 1) && !sa.current.zone.smoke && !sa.current.zone.strobes && sa.current.zone.stepFree, 'SAM08_UNSAFE_SHARED_DESTINATION');
    const overbooked = await sql(`select count(*)::integer n from app_private.fn_zones z where z.event_id=${literal(eventId)}::uuid and (app_private.fn_zone_occupancy(z.id)->>'effectivePersons')::integer>z.capacity`);
    assert(Number(overbooked[0].n) === 0, 'SAM08_CAPACITY_OVERRUN');
    await command(b, 'party.leave');
    pass('SAM-08', 'simultaneous join/preference commands settle on one shared route satisfying current members and capacity', { remaining: 'Checks committed responses/snapshots; no physical walk or transient-pixel timing claim.' });
    // Closed finale is never a successful visit. Explicit reopening and resume
    // must create a single current finale before it can be scanned.
    sa = await state(a);
    await command(a, 'journey.finish', { expectedVersion: sa.journey.version });
    sa = await state(a);
    assert(sa.current?.zone.type === 'finale', 'ROU11_FINALE_RETURN_REQUIRED');
    let fs = (await state(admin)).zones.find(zone => zone.id === finale.id);
    await command(admin, 'zone.status', { zoneId: finale.id, expectedVersion: fs.version, status: 'closed', reason: 'Synthetische finale tijdelijk niet beschikbaar' });
    await reject(a, 'journey.complete', { destinationId: sa.current.id, expectedVersion: sa.journey.version, code: await code(finale.id) }, [409]);
    await command(admin, 'admin.recalculate', { partyId: sa.journey.id, returnToDuinpad: true });
    next = await state(a);
    assert(!next.current && next.journey.state === 'waiting' && /hulppunt|veilige/.test(next.journey.reason) && !next.progress.visits.some(visit => visit.zoneId === finale.id), 'ROU11_UNAVAILABLE_FINALE_FALSE_FINISH');
    fs = (await state(admin)).zones.find(zone => zone.id === finale.id);
    await command(admin, 'zone.status', { zoneId: finale.id, expectedVersion: fs.version, status: 'open', reason: 'Synthetische finale gecontroleerd heropenen' });
    await command(a, 'journey.resume', { expectedVersion: next.journey.version });
    sa = await state(a);
    assert(sa.current?.zone.type === 'finale' && sa.journey.state !== 'finished', 'ROU11_REOPEN_DID_NOT_RESTORE_FINAL_DESTINATION');
    const activeInvite = await command(b, 'party.invite');
    await command(a, 'journey.complete', { destinationId: sa.current.id, expectedVersion: sa.journey.version, code: await code(finale.id) });
    sa = await state(a);
    assert(sa.journey.state === 'finished' && sa.progress.visits.filter(visit => visit.zoneId === finale.id).length === 1, 'ROU11_FINALE_NOT_EXACTLY_ONCE');
    pass('ROU-11', 'closed finale yields wait/help; reopening requires one authoritative finale scan');
    const completionBefore = JSON.stringify(sa.progress);
    await reject(a, 'party.join', { token: activeInvite.value.result.token, consent: true }, [403]);
    assert(JSON.stringify((await state(a)).progress) === completionBefore && (await state(b)).journey.state !== 'finished', 'SAM09_COMPLETION_COPIED_TO_ACTIVE_PARTY');
    pass('SAM-09', 'finished registration cannot join active party or copy completion/history');
    const visited = sa.progress.visits.find(visit => visit.zoneId !== finale.id);
    assert(visited, 'REG07_VISITED_HOUSE_REQUIRED');
    await fixture(`update app_private.fn_zones set owner_id=${literal(resident.id)}::uuid where event_id=eid and run_id=own_run and synthetic and id=${literal(visited.zoneId)}::uuid;`);
    const thanksKey = randomUUID();
    const thanks = { zoneId: visited.zoneId, text: 'Bedankt voor het licht in deze uitsluitend synthetische proef.' };
    await command(a, 'thanks.send', thanks, false, thanksKey);
    await command(a, 'thanks.send', thanks, false, thanksKey);
    await command(a, 'thanks.send', thanks);
    const evaluationKey = randomUUID();
    await command(a, 'evaluation.save', { rating: 5, text: 'Algemeen bedankje uit de synthetische pakketproef.' }, false, evaluationKey);
    await command(a, 'evaluation.save', { rating: 5, text: 'Algemeen bedankje uit de synthetische pakketproef.' }, false, evaluationKey);
    const visibleThanks = (await state(resident)).ownThanks.find(item => item.zoneId === visited.zoneId);
    const thanksCounts = await sql(`select (select count(*) from app_private.fn_thanks where event_id=${literal(eventId)}::uuid and registration_id=${literal(sa.registration.id)}::uuid and zone_id=${literal(visited.zoneId)}::uuid)::integer thanks,(select count(*) from app_private.fn_evaluations where event_id=${literal(eventId)}::uuid and registration_id=${literal(sa.registration.id)}::uuid)::integer evaluations,(select count(*) from app_private.fn_mail_sink where event_id=${literal(eventId)}::uuid)::integer mail`);
    assert(visibleThanks?.count === 1 && Number(thanksCounts[0].thanks) === 1 && Number(thanksCounts[0].evaluations) === 1 && Number(thanksCounts[0].mail) === 0, 'REG07_THANKS_REPLAY_OR_VISIBILITY_FAILED');
    pass('REG-07', 'general evaluation and visited-house thanks replay once; owner sees one durable thank-you', { delivery: 'durable records only; zero sink/outbound mail', remaining: 'No email delivery action exists in this thanks flow; no external delivery claim.' });
    await settings({ closed: true });
    sb = await state(b);
    await reject(b, 'activity.book', { activityId: sb.activities[0].id });
    await reject(b, 'party.join', { token: activeInvite.value.result.token, consent: true });
    assert((await state(b)).event.closed && (await state(a)).journey.state === 'finished', 'EDGE_CLOSED_EDITION_REACTIVATED');
    await settings({ closed: false });
    await reload(pa); await pa.getByRole('button', { name: 'Nachtpas', exact: true }).click();
    const seals = await pa.locator('.fn-seals').innerText();
    assert(/bezoekzegel/i.test(seals) && !/visit:[0-9a-f-]{36}|quest:|game-[123]|riddle-[123]/i.test(seals), 'EDGE_INTERNAL_AWARD_REFERENCE_RENDERED');
    await screen(pa, 'hosted-edge-finished-pass');
    assert(pageErrors === 0, 'EDGE_BROWSER_RUNTIME_ERROR');
    pass('CLOSED-EDITION', 'closed edition refuses new bookings and joins while preserving recorded finale');
    detail.status = 'passed';
  } catch (error) { failure = error; detail.status = 'failed'; }
  finally {
    for (const person of people) await person.context.setOffline(false).catch(() => {});
    for (const page of pages) await page.close().catch(() => {});
    for (const context of contexts) await context.close().catch(() => {});
    const cleanupErrors = [];
    if (eventId) {
      try {
        await select(admin);
        let current = await state(admin); runId ??= current.event.runId;
        assert(current.event.runId === runId, 'EDGE_CLEANUP_RUN_CHANGED');
        if (current.event.closed) { await settings({ closed: false }); current = await state(admin); }
        const realRows = await sql(`select count(*)::integer n from app_private.fn_registrations where event_id=${literal(eventId)}::uuid and not synthetic`);
        assert(Number(realRows[0]?.n) === 0, 'EDGE_CLEANUP_NON_SYNTHETIC_REGISTRATION');
        const before = await financial();
        await command(admin, 'test.reset', { confirmation: slug, runId });
        current = await state(admin);
        assert(current.event.runId !== runId, 'EDGE_CLEANUP_RUN_NOT_ARCHIVED');
        await settings({ closed: true });
        const after = await financial();
        assert(before.orders === after.orders && before.ledger === after.ledger && Number(after.audit_count) >= Number(before.audit_count), 'EDGE_CLEANUP_FINANCIAL_HISTORY_CHANGED');
        detail.cleanup = { originalRunArchived: true, siblingClosed: true, ordersPreserved: true, ledgerPreserved: true, auditPreserved: true, authDeleted: 0, actorsBanned: 0 };
      } catch {
        cleanupErrors.push('EDGE_OWN_SIBLING_ARCHIVE_FAILED');
        // Closing remains safe even when an unexpected non-synthetic record
        // correctly prevents reset. Preserve it and report cleanup as failed.
        try { await settings({ closed: true }); } catch { cleanupErrors.push('EDGE_FAIL_CLOSED_FAILED'); }
      }
      try {
        await sql(`update app_private.event_capabilities c set revoked_at=coalesce(c.revoked_at,now()) where c.event_id=${literal(eventId)}::uuid and c.user_id=${literal(admin.id)}::uuid and exists(select 1 from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.id=c.event_id and e.slug=${literal(slug)} and f.environment='staging' and f.is_test) and exists(select 1 from auth.users u where u.id=c.user_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})`, true);
      } catch { cleanupErrors.push('EDGE_OWN_CAPABILITY_REVOKE_FAILED'); }
    }
    for (const person of people) { try { await select(person, parentSlug); } catch { cleanupErrors.push('EDGE_PARENT_CONTEXT_RESTORE_FAILED'); } }
    try {
      const parentAfter = await sql(`select md5(to_jsonb(f)::text) digest from app_private.fn_events f where event_id=${literal(parentEventId)}::uuid`);
      assert(parentBefore[0]?.digest === parentAfter[0]?.digest, 'EDGE_PARENT_EVENT_CHANGED');
    } catch { cleanupErrors.push('EDGE_PARENT_PRESERVATION_FAILED'); }
    detail.completedAt = new Date().toISOString();
    if (cleanupErrors.length) { detail.cleanupFailure = cleanupErrors.join(';'); detail.status = 'failed'; failure ??= new Error('EDGE_CLEANUP_FAILED'); }
    else if (eventId) pass('PRESERVATION', 'only own sibling archived; financial/Auth/audit history and parent edition preserved');
    detail.checks = report.checks.length - startingChecks;
  }
  if (failure) throw failure;
}
