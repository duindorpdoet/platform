// Invoked only by the verified hosted acceptance runner. No Auth accounts,
// passwords, OTP, provider payments or outbound messages are created here.
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function runRegieAcceptance({ base, slug: parentSlug, eventId: parentEventId, run, admin, a, b, resident, support, sql, app, assert, checked, literal, report, directory }) {
  assert(base === 'https://staging-halloween.duindorpdoet.nl', 'REGIE_STAGING_ORIGIN_REQUIRED');
  assert(/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA ?? '') && process.env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA === process.env.GITHUB_SHA, 'REGIE_VERIFIED_RELEASE_REQUIRED');
  assert(parentSlug.startsWith('frightnight-2027-test-acceptance-') && UUID.test(parentEventId), 'REGIE_PARENT_SCOPE_REQUIRED');
  const people = [admin, a, b, resident, support];
  assert(people.every(person => UUID.test(person.id) && person.email?.endsWith('@example.invalid') && person.context), 'REGIE_EXISTING_INVALID_ACTORS_REQUIRED');
  const proof = await sql(`select count(*)::integer n from auth.users where id in (${people.map(person => `${literal(person.id)}::uuid`).join(',')}) and email like '%@example.invalid' and raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}`);
  assert(Number(proof[0]?.n) === people.length, 'REGIE_SYNTHETIC_RUN_BINDING_REQUIRED');
  const tag = randomUUID().slice(0, 8);
  const slug = `${parentSlug}-regie-${tag}`;
  assert(slug.length <= 100 && /^[a-z0-9-]+$/.test(slug), 'REGIE_SIBLING_SLUG_INVALID');
  const prefix = `REG01-${tag}`;
  const startingChecks = report.checks.length;
  const detail = { revision: process.env.GITHUB_SHA, edition: slug, testedAt: new Date().toISOString(), scope: 'fresh-own-sibling-existing-invalid-actors-only', provider: 'not exercised; payment rows are explicit synthetic list fixtures', mail: 'no mail commands or delivery', status: 'running' };
  report.regieAcceptance = detail;
  let eventId;
  let runId;
  let page;
  let pageErrors = 0;
  let failure;
  const parentBefore = await sql(`select md5(to_jsonb(f)::text) digest from app_private.fn_events f where f.event_id=${literal(parentEventId)}::uuid`);
  const pass = (name, values = {}) => checked(name, { module: 'REG01-REG02', edition: slug, ...values });
  async function select(person, selectedSlug) {
    const response = await person.context.request.post(`${base}/api/frightnight/edition`, { headers: { Origin: base }, data: { slug: selectedSlug } });
    assert(response.ok(), 'REGIE_SIGNED_EDITION_SELECTION_FAILED');
    assert((await response.json()).data.selected === selectedSlug, 'REGIE_SIGNED_EDITION_SELECTION_MISMATCH');
  }
  async function state(person) {
    const response = await person.context.request.get(`${base}/api/frightnight/snapshot`);
    assert(response.ok(), 'REGIE_SNAPSHOT_FAILED');
    const result = (await response.json()).data;
    assert(result.event.slug === slug && result.event.id === eventId && result.event.test && result.event.environment === 'staging', 'REGIE_EFFECTIVE_SCOPE_MISMATCH');
    return result;
  }
  async function command(person, operation, payload = {}, allowFailure = false) {
    return app(person, operation, payload, randomUUID(), allowFailure);
  }
  async function listResponse(resource, predicate, action) {
    const waiting = page.waitForResponse(response => {
      if (new URL(response.url()).pathname !== '/api/frightnight/admin/list' || response.request().method() !== 'POST') return false;
      const body = response.request().postDataJSON();
      return body.resource === resource && predicate(body);
    });
    const [response] = await Promise.all([waiting, action()]);
    assert(response.ok(), 'REGIE_SERVER_LIST_REQUEST_FAILED');
    assert(response.request().postDataJSON().limit === 50 && !new URL(response.url()).search, 'REGIE_POST_BODY_AND_BOUND_REQUIRED');
    return (await response.json()).data;
  }
  const resourceNames = { registrations: 'inschrijvingen', zones: 'zones', payments: 'betalingen', incidents: 'hulpvragen', announcements: 'organisatieberichten' };
  async function search(resource, query) {
    return listResponse(resource, body => body.search === query && body.cursor === 0, () => page.getByRole('textbox', { name: `Zoek in alle ${resourceNames[resource]}`, exact: true }).fill(query));
  }
  async function filter(resource, name, value) {
    return listResponse(resource, body => body.cursor === 0, () => page.getByRole('combobox', { name, exact: true }).selectOption(value));
  }
  async function screen(name) {
    for (const width of [390, 1440]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });
      assert(!await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), 'REGIE_RESPONSIVE_OVERFLOW');
      const file = `${name}-${width}.png`;
      await page.screenshot({ path: join(directory, file), fullPage: true });
      report.screenshots.push(file);
    }
  }
  async function manualCode(zoneId) {
    const response = await admin.context.request.get(`${base}/api/frightnight/qr${zoneId ? `?zoneId=${encodeURIComponent(zoneId)}` : ''}`);
    assert(response.ok(), 'REGIE_SYNTHETIC_QR_EXPORT_FAILED');
    const code = (await response.text()).match(/<code>([^<]+)<\/code>/)?.[1];
    assert(code, 'REGIE_MANUAL_CODE_MISSING');
    return code;
  }
  try {
    const copied = await app(admin, 'test.copy', { slug });
    eventId = copied.value.result.eventId;
    assert(UUID.test(eventId) && eventId !== parentEventId, 'REGIE_FRESH_EVENT_REQUIRED');
    await select(admin, slug);
    await command(admin, 'test.seed');
    await command(admin, 'test.clock', { time: '2027-10-30T15:05:00Z' });
    const initial = await state(admin);
    runId = initial.event.runId;
    detail.eventId = eventId;
    detail.runId = runId;
    assert(UUID.test(runId), 'REGIE_RUN_REQUIRED');
    // These are scoped synthetic fixtures, not payment confirmations. Household
    // references remain NULL; existing people, PSP data and legacy mail are untouched.
    await sql(`do $$ declare eid uuid; own_run uuid; reg_id uuid; party_id uuid; owner uuid; n integer; begin
      select e.id,f.run_id into eid,own_run from app_private.events e join app_private.fn_events f on f.event_id=e.id
        where e.id=${literal(eventId)}::uuid and e.slug=${literal(slug)} and f.run_id=${literal(runId)}::uuid and f.environment='staging' and f.is_test and not f.closed;
      if eid is null or exists(select 1 from app_private.fn_registrations r where r.event_id=eid and not r.synthetic) then raise exception 'REGIE_FIXTURE_SCOPE_REQUIRED'; end if;
      for n in 1..2 loop
        owner:=case n when 1 then ${literal(a.id)}::uuid else ${literal(b.id)}::uuid end;
        if not exists(select 1 from auth.users u where u.id=owner and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}) then raise exception 'REGIE_INVALID_ACTOR'; end if;
        insert into app_private.fn_registrations(event_id,owner_id,terms_version,consented_at,consent_actor,label,route_type,adults,children,max_intensity,status,payment_status,amount_cents,start_slot,synthetic,run_id)
          values(eid,owner,'2027-test-v1',now(),owner,'REG02 synthetisch gezelschap '||n,case n when 1 then 'roots' else 'lantern' end,1,1,2,'active','paid',700,case n when 1 then '2027-10-30T16:30:00Z'::timestamptz else '2027-10-30T15:00:00Z'::timestamptz end,true,own_run) returning id into reg_id;
        insert into app_private.fn_parties(event_id,run_id) values(eid,own_run) returning id into party_id;
        insert into app_private.fn_members(event_id,party_id,registration_id) values(eid,party_id,reg_id);
      end loop;
      insert into app_private.fn_registrations(event_id,label,route_type,adults,children,max_intensity,status,payment_status,amount_cents,synthetic,run_id,created_at)
        select eid,${literal(prefix)}||' gezelschap '||lpad(i::text,3,'0'),case when i%2=0 then 'roots' else 'lantern' end,1,1,2,case when i%3=0 then 'draft' else 'active' end,case when i%3=0 then 'unpaid' else 'paid' end,700,true,own_run,now()-interval '1 day'+i*interval '1 second' from generate_series(1,65)i;
      insert into app_private.fn_zones(event_id,name,address,type,intensity,capacity,status,review_status,opens_at,closes_at,description,synthetic,run_id,token_hash)
        select eid,${literal(prefix)}||' zone '||lpad(i::text,3,'0'),'Uitsluitend synthetisch regieadres '||i,'candy',0,8,case i%4 when 0 then 'closed' when 1 then 'open' when 2 then 'busy' else 'paused' end,'approved','2027-10-30T15:00:00Z','2027-10-30T19:00:00Z','Synthetische fixture voor gepagineerde regiecontrole, zonder fysieke wandelverbinding.',true,own_run,extensions.digest(eid::text||':regie:'||i::text,'sha256') from generate_series(1,65)i;
      insert into app_private.fn_orders(event_id,registration_id,provider,amount_cents,status,idempotency_key,created_at)
        select eid,r.id,'contract',r.amount_cents,case when right(r.label,3)::integer%4=0 then 'failed' when right(r.label,3)::integer%3=0 then 'open' else 'paid' end,gen_random_uuid(),r.created_at from app_private.fn_registrations r where r.event_id=eid and r.run_id=own_run and r.synthetic and r.label like ${literal(prefix + ' gezelschap %')};
      insert into app_private.fn_incidents(event_id,actor_id,category,text,status,response_text,created_at)
        select eid,case when i%2=0 then ${literal(a.id)}::uuid else ${literal(b.id)}::uuid end,'route',${literal(prefix)}||' hulpvraag '||lpad(i::text,3,'0'),case when i%3=0 then 'resolved' else 'open' end,case when i%3=0 then 'Synthetisch fixtureantwoord' else null end,now()-interval '1 day'+i*interval '1 second' from generate_series(1,65)i;
      insert into app_private.fn_announcements(event_id,text,audience,created_at,updated_at)
        select eid,${literal(prefix)}||' organisatiebericht '||lpad(i::text,3,'0'),'all',now()-interval '1 day'+i*interval '1 second',now()-interval '1 day'+i*interval '1 second' from generate_series(1,65)i;
    end $$`, true);
    await select(a, slug);
    await select(b, slug);
    pass('REG01 bounded synthetic fixtures in separate sibling', { rowsPerResource: 65, resources: 5 });
    page = await admin.context.newPage();
    page.on('pageerror', () => { pageErrors++; });
    await page.goto(`${base}/avondregie`, { waitUntil: 'domcontentloaded' });
    await page.locator('.fn-environment-nav').waitFor();
    const queries = [];
    page.on('request', request => { if (new URL(request.url()).pathname === '/api/frightnight/admin/list') queries.push({ method: request.method(), search: new URL(request.url()).search }); });
    for (const [tab, resource, suffix, status, expected] of [
      ['deelnemers', 'registrations', 'gezelschap', 'active', 44], ['zones', 'zones', 'zone', 'open', 17],
      ['betalingen', 'payments', 'gezelschap', 'paid', 33], ['meldingen', 'incidents', 'hulpvraag', 'open', 44],
      ['meldingen', 'announcements', 'organisatiebericht', '', 65],
    ]) {
      await page.getByRole('button', { name: tab, exact: true }).click();
      const query = `${prefix} ${suffix}`;
      let data = await search(resource, query);
      assert(data.total === 65 && data.items.length === 50 && data.nextCursor === 50, 'REG01_GLOBAL_COUNT_OR_FIRST_PAGE_FAILED');
      const panel = page.locator('.fn-panel').filter({ has: page.getByRole('textbox', { name: `Zoek in alle ${resourceNames[resource]}`, exact: true }) });
      data = await listResponse(resource, body => body.cursor === 50, () => panel.getByRole('button', { name: 'Volgende', exact: true }).click());
      assert(data.total === 65 && data.items.length === 15 && data.nextCursor === null, 'REG01_SECOND_PAGE_FAILED');
      const row = data.items[0];
      const exact = resource === 'registrations' ? row.label : resource === 'zones' ? row.name : resource === 'payments' ? row.registrationLabel : row.text;
      data = await search(resource, exact);
      assert(data.total === 1 && data.items.length === 1, 'REG01_SEARCH_BEYOND_FIRST_PAGE_FAILED');
      await search(resource, query);
      if (status) {
        data = await filter(resource, resource === 'registrations' ? 'Filter inschrijvingsstatus' : 'Filter status', status);
        assert(data.total === expected, 'REG01_FILTERED_GLOBAL_COUNT_FAILED');
        if (['registrations', 'payments', 'incidents'].includes(resource)) {
          data = await filter(resource, 'Filter avonddeel', 'roots');
          assert(data.total === (resource === 'payments' ? 11 : 22), 'REG01_COMBINED_ROUTE_STATUS_COUNT_FAILED');
        }
      }
      await screen(`hosted-reg01-${resource}`);
      pass(`REG01 ${resource}: search, two pages, global totals and applicable filters`, { fixtureMatches: 65, firstPage: 50, secondPage: 15, filteredTotal: data.total });
    }
    assert(queries.length <= 45 && queries.every(query => query.method === 'POST' && query.search === ''), 'REG01_UNBOUNDED_REQUESTS_OR_QUERY_PII');
    pass('REG01 bounded POST requests keep search values out of URLs', { listRequests: queries.length, maximum: 45 });
    // REG-05: four new ownerless records in this exact synthetic run exercise
    // the actual browser CSV download, without modifying the 65-row fixtures.
    const formulaLabels = ['=', '+', '-', '@'].map(marker => `${marker}FORMULA-${tag} "quoted"; own sibling`);
    await sql(`do $$ declare eid uuid; own_run uuid; begin
      select e.id,f.run_id into eid,own_run from app_private.events e join app_private.fn_events f on f.event_id=e.id
        where e.id=${literal(eventId)}::uuid and e.slug=${literal(slug)} and f.run_id=${literal(runId)}::uuid and f.environment='staging' and f.is_test and not f.closed;
      if eid is null then raise exception 'REG05_FIXTURE_SCOPE_REQUIRED'; end if;
      insert into app_private.fn_registrations(event_id,label,route_type,adults,children,max_intensity,amount_cents,synthetic,run_id)
        select eid,v.label,'lantern',1,0,1,350,true,own_run from(values ${formulaLabels.map(label => `(${literal(label)})`).join(',')})v(label);
    end $$`, true);
    await page.getByRole('button', { name: 'deelnemers', exact: true }).click();
    const formulaRows = await search('registrations', 'FORMULA');
    assert(formulaRows.total === 4 && formulaRows.items.length === 4 && formulaRows.nextCursor === null && formulaRows.items.every(item => formulaLabels.includes(item.label)), 'REG05_EXACT_EXPORT_FIXTURES_REQUIRED');
    const exportPanel = page.locator('.fn-panel').filter({ has: page.getByRole('textbox', { name: 'Zoek in alle inschrijvingen', exact: true }) });
    const downloading = page.waitForEvent('download');
    await exportPanel.getByRole('button', { name: 'Exporteer pagina', exact: true }).click();
    const download = await downloading;
    assert(download.suggestedFilename() === 'frightnight-registrations-pagina-1.csv', 'REG05_CSV_FILENAME_REQUIRED');
    const stream = await download.createReadStream();
    assert(stream, 'REG05_CSV_DOWNLOAD_STREAM_MISSING');
    const chunks = []; let bytes = 0;
    for await (const chunk of stream) {
      bytes += chunk.length;
      assert(bytes <= 16_384, 'REG05_BOUNDED_CSV_DOWNLOAD_REQUIRED');
      chunks.push(chunk);
    }
    const csv = Buffer.concat(chunks).toString('utf8');
    assert(csv.startsWith('\uFEFF'), 'REG05_UTF8_BOM_REQUIRED');
    const csvLines = csv.slice(1).split('\r\n');
    assert(csvLines.length === 5 && csvLines[0] === '"Gezelschap";"Inschrijving";"Tocht";"Personen";"Max. spanning";"Betaling";"Bedrag"', 'REG05_FILTERED_PAGE_AND_HEADER_REQUIRED');
    assert(csvLines.slice(1).every(line => /^"(?:[^"]|"")*"(?:;"(?:[^"]|"")*"){6}$/.test(line)), 'REG05_SEVEN_CORRECTLY_QUOTED_CELLS_REQUIRED');
    for (const label of formulaLabels) {
      const escaped = label.replaceAll('"', '""');
      assert(csvLines.slice(1).filter(line => line.startsWith(`"'${escaped}";`)).length === 1, 'REG05_FORMULA_APOSTROPHE_AND_QUOTE_ESCAPING_REQUIRED');
      assert(!csvLines.slice(1).some(line => line.startsWith(`"${escaped}";`)), 'REG05_EXECUTABLE_FORMULA_EXPORTED');
    }
    const deniedFormulaExport = await a.context.request.post(`${base}/api/frightnight/admin/list`, { headers: { Origin: base }, data: { resource: 'registrations', cursor: 0, limit: 50, search: 'FORMULA' } });
    const deniedFormulaBody = await deniedFormulaExport.json();
    assert(deniedFormulaExport.status() === 403 && !deniedFormulaBody.data?.items, 'REG05_PARTICIPANT_EXPORT_DATA_EXPOSED');
    detail.csvExport = { source: 'actual filtered browser download', syntheticRows: 4, quotedCellsPerRow: 7, neutralizedPrefixes: ['=', '+', '-', '@'], quotedSemicolonsPreserved: true, embeddedQuotesEscaped: true, participantDataDenied: true, bytes };
    pass('REG05 actual filtered CSV download neutralizes four formula prefixes, escapes quotes and denies participant export data', { rows: 4, columns: 7 });
    // Real JWT actors, capability denial and an explicit cross-edition target.
    const deniedList = await a.context.request.post(`${base}/api/frightnight/admin/list`, { headers: { Origin: base }, data: { resource: 'registrations', cursor: 0, limit: 50, search: prefix } });
    assert(deniedList.status() === 403, 'REG01_PARTICIPANT_LIST_CAPABILITY_BYPASS');
    const deniedPublish = await command(a, 'admin.announcement', { text: 'Verboden synthetische regiehandeling', audience: 'all' }, true);
    assert(deniedPublish.status === 403, 'REG02_PARTICIPANT_PUBLISH_CAPABILITY_BYPASS');
    const deniedScope = await support.context.request.post(`${base}/api/frightnight/edition`, { headers: { Origin: base }, data: { slug } });
    assert(deniedScope.status() === 403, 'REG01_UNASSIGNED_SUPPORT_ENTERED_SIBLING');
    const parents = await sql(`select id from app_private.fn_registrations where event_id=${literal(parentEventId)}::uuid and owner_id=${literal(a.id)}::uuid limit 1`);
    assert(parents[0]?.id, 'REG02_PARENT_FIXTURE_TARGET_REQUIRED');
    const deniedTarget = await command(admin, 'admin.announcement', { text: 'Synthetische kruiseditieproef', audience: 'registration', registrationId: parents[0].id }, true);
    assert([403, 404, 409, 422].includes(deniedTarget.status), 'REG02_CROSS_EDITION_RECIPIENT_ACCEPTED');
    pass('REG01/02 actor, capability, edition and cross-edition target denials');
    await page.getByRole('button', { name: 'meldingen', exact: true }).click();
    const text = `REG02-${tag} organisatiebericht`;
    await page.getByLabel('Bericht aan deze editie', { exact: true }).fill(text);
    await page.getByLabel(/^Doelgroep/).selectOption('all');
    await page.getByLabel('Ik heb de tekst en de bedoelde ontvangers gecontroleerd.').check();
    const createResponse = page.waitForResponse(response => new URL(response.url()).pathname === '/api/frightnight/command' && response.request().method() === 'POST');
    await page.getByRole('button', { name: 'Bericht publiceren', exact: true }).click();
    assert((await createResponse).ok(), 'REG02_UI_CREATE_FAILED');
    let as = await state(a);
    let bs = await state(b);
    const message = as.announcements.find(item => item.text === text);
    assert(message && bs.announcements.some(item => item.id === message.id), 'REG02_GENERAL_AUDIENCE_FAILED');
    await search('announcements', text);
    async function editAudience(audience, targetId) {
      await page.getByRole('row').filter({ hasText: text }).getByRole('button', { name: 'Bericht wijzigen', exact: true }).click();
      await page.getByLabel(/^Doelgroep/).selectOption(audience);
      if (audience === 'registration') {
        await page.getByLabel(/^Gezelschap voor dit bericht/).selectOption('manual');
        await page.getByLabel(/^Inschrijvings-ID/).fill(targetId);
      }
      if (audience === 'zone') await page.getByLabel(/^Zone voor dit bericht/).selectOption(targetId);
      await page.getByLabel('Ik heb de tekst en de bedoelde ontvangers gecontroleerd.').check();
      const waiting = page.waitForResponse(response => new URL(response.url()).pathname === '/api/frightnight/command' && response.request().method() === 'POST');
      await page.getByRole('button', { name: 'Bericht en doelgroep bijwerken', exact: true }).click();
      const response = await waiting;
      assert(response.ok() && response.request().postDataJSON().payload.id === message.id && response.request().postDataJSON().payload.expectedVersion >= 1, 'REG02_UI_VERSIONED_UPDATE_FAILED');
      await page.getByRole('heading', { name: 'Nieuw organisatiebericht', exact: true }).waitFor();
    }
    await editAudience('roots');
    as = await state(a); bs = await state(b);
    assert(as.announcements.some(item => item.id === message.id) && !bs.announcements.some(item => item.id === message.id), 'REG02_ROUTE_AUDIENCE_FAILED');
    await editAudience('registration', bs.registration.id);
    as = await state(a); bs = await state(b);
    assert(!as.announcements.some(item => item.id === message.id) && bs.announcements.some(item => item.id === message.id), 'REG02_EXPLICIT_REGISTRATION_AUDIENCE_FAILED');
    pass('REG02 UI create and versioned audience edits: everyone, roots and exact registration');
    // The route fixture is synthetic; no external walking, PSP or mail provider.
    await command(admin, 'test.walk.fixture');
    bs = await state(b);
    await command(b, 'journey.start', { code: await manualCode(), expectedVersion: bs.journey.version });
    bs = await state(b);
    assert(bs.current, 'REG02_CURRENT_SYNTHETIC_DESTINATION_REQUIRED');
    await editAudience('zone', bs.current.zoneId ?? bs.current.zone.id);
    as = await state(a); bs = await state(b);
    assert(!as.announcements.some(item => item.id === message.id) && bs.announcements.some(item => item.id === message.id), 'REG02_CURRENT_ZONE_AUDIENCE_FAILED');
    await command(b, 'journey.pause', { expectedVersion: bs.journey.version });
    assert(!(await state(b)).announcements.some(item => item.id === message.id), 'REG02_RELEASED_ZONE_MESSAGE_RETAINED');
    await screen('hosted-reg02-audience');
    assert(pageErrors === 0, 'REGIE_BROWSER_PAGE_ERROR');
    pass('REG02 only current destination sees zone message; release removes it', { screens: [390, 1440], pageErrors });
    detail.status = 'passed';
  } catch (error) {
    failure = error;
    detail.status = 'failed';
  } finally {
    if (page) await page.close().catch(() => {});
    const cleanupErrors = [];
    if (eventId) {
      try {
        await select(admin, slug);
        const current = await state(admin);
        runId ??= current.event.runId;
        assert(current.event.runId === runId, 'REGIE_CLEANUP_RUN_CHANGED');
        const onlySynthetic = await sql(`select count(*)::integer n from app_private.fn_registrations where event_id=${literal(eventId)}::uuid and not synthetic`);
        assert(Number(onlySynthetic[0].n) === 0, 'REGIE_CLEANUP_REAL_REGISTRATION_BLOCKED');
        const financial = await sql(`select (select md5(coalesce(jsonb_agg(to_jsonb(o) order by o.id)::text,'')) from app_private.fn_orders o where o.event_id=${literal(eventId)}::uuid) orders,(select md5(coalesce(jsonb_agg(to_jsonb(l) order by l.id)::text,'')) from app_private.fn_ledger l where l.event_id=${literal(eventId)}::uuid) ledger,(select count(*)::integer from app_private.fn_audit where event_id=${literal(eventId)}::uuid) audit_count`);
        const reset = await command(admin, 'test.reset', { confirmation: slug, runId });
        assert(reset.status === 200, 'REGIE_CLEANUP_RESET_FAILED');
        const resetState = await state(admin);
        assert(resetState.event.runId !== runId, 'REGIE_CLEANUP_DID_NOT_ARCHIVE_RUN');
        const close = await command(admin, 'admin.settings', { closed: true, expectedVersion: resetState.event.version, confirmation: slug, reason: 'Afzonderlijke synthetische REG01/02-acceptatierun gecontroleerd archiveren' });
        assert(close.status === 200, 'REGIE_CLEANUP_CLOSE_FAILED');
        const afterFinancial = await sql(`select (select md5(coalesce(jsonb_agg(to_jsonb(o) order by o.id)::text,'')) from app_private.fn_orders o where o.event_id=${literal(eventId)}::uuid) orders,(select md5(coalesce(jsonb_agg(to_jsonb(l) order by l.id)::text,'')) from app_private.fn_ledger l where l.event_id=${literal(eventId)}::uuid) ledger,(select count(*)::integer from app_private.fn_audit where event_id=${literal(eventId)}::uuid) audit_count`);
        assert(financial[0].orders === afterFinancial[0].orders && financial[0].ledger === afterFinancial[0].ledger && Number(afterFinancial[0].audit_count) >= Number(financial[0].audit_count), 'REGIE_CLEANUP_FINANCIAL_HISTORY_CHANGED');
        detail.cleanup = { originalRunArchived: true, siblingClosed: true, paymentsPreserved: true, ledgerPreserved: true, auditPreserved: true, authDeleted: 0, actorsBanned: 0 };
      } catch { cleanupErrors.push('REGIE_OWN_SIBLING_ARCHIVE_FAILED'); }
      try {
        await sql(`update app_private.event_capabilities c set revoked_at=coalesce(c.revoked_at,now()) where c.event_id=${literal(eventId)}::uuid and c.user_id=${literal(admin.id)}::uuid and exists(select 1 from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.id=c.event_id and e.slug=${literal(slug)} and f.environment='staging' and f.is_test) and exists(select 1 from auth.users u where u.id=c.user_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})`, true);
      } catch { cleanupErrors.push('REGIE_OWN_CAPABILITY_REVOKE_FAILED'); }
    }
    for (const person of people) {
      try { await select(person, parentSlug); } catch { cleanupErrors.push('REGIE_PARENT_CONTEXT_RESTORE_FAILED'); }
    }
    try {
      const parentAfter = await sql(`select md5(to_jsonb(f)::text) digest from app_private.fn_events f where f.event_id=${literal(parentEventId)}::uuid`);
      assert(parentBefore[0]?.digest === parentAfter[0]?.digest, 'REGIE_PARENT_EVENT_CHANGED');
    } catch { cleanupErrors.push('REGIE_PARENT_PRESERVATION_FAILED'); }
    detail.completedAt = new Date().toISOString();
    if (cleanupErrors.length) {
      detail.cleanupFailure = cleanupErrors.join(';');
      detail.status = 'failed';
      failure ??= new Error('REGIE_CLEANUP_FAILED');
    } else if (eventId) pass('REG01/02 own sibling archived, financial history preserved and parent contexts restored');
    detail.checks = report.checks.length - startingChecks;
  }
  if (failure) throw failure;
}
