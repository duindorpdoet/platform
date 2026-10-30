#!/usr/bin/env node
/** Local review only: no network, database, route application or messaging. */
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { proposeJointRoutes, measureJointRoutes, validateJointRoutes, JOINT_ROUTE_SEARCH_LIMITS } from '../../lib/domain/joint-route-planner.ts';

const plannerSourceFile = fileURLToPath(new URL('../../lib/domain/joint-route-planner.ts', import.meta.url));
const plannerSourceSha256 = createHash('sha256').update(await readFile(plannerSourceFile)).digest('hex');

const options = {};
for (let index = 2; index < process.argv.length; index++) {
  const option = process.argv[index];
  if (option === '--help') {
    console.log('Gebruik: node scripts/diagnostics/joint-route-65-coverage-report.mjs --input <production-v2.json> --candidate <local-v3.json> --metadata <private-metadata.json> --output <report-directory> [--private-output <temporary-directory>]');
    process.exit(0);
  }
  if (!['--input', '--candidate', '--metadata', '--output', '--private-output'].includes(option) || !process.argv[index + 1] || process.argv[index + 1].startsWith('--') || options[option]) throw new Error(`Ongeldig of dubbel argument: ${option}`);
  options[option] = resolve(process.argv[++index]);
}
for (const name of ['--input', '--candidate', '--metadata', '--output']) if (!options[name]) throw new Error(`${name} ontbreekt; gebruik --help.`);
const read = async path => JSON.parse(await readFile(path, 'utf8'));
const production = await read(options['--input']), candidate = await read(options['--candidate']), metadata = await read(options['--metadata']);
if (production.sourceHash !== candidate.sourceHash || production.boardHash !== candidate.boardHash || metadata.sourceHash !== production.sourceHash || metadata.boardHash !== production.boardHash) throw new Error('SNAPSHOT_HASH_MISMATCH');
if (candidate.policyVersion !== 'joint-reception-v3' || candidate.maxTotalWalkingSeconds !== 3900 || candidate.maxEarlyFinishSeconds !== 1800) throw new Error('EXPECTED_EXPLICIT_V3_65_MINUTE_POLICY');
const groups = new Map(candidate.groups.map(group => [group.id, group])), portals = new Map(candidate.portals.map(portal => [portal.id, portal]));
const codes = new Map([...candidate.groups, ...candidate.portals].map(item => [item.id, item.code]));
if ([...codes.values()].some(code => !/^[GP]-\d+$/.test(code))) throw new Error('CODE_REQUIRED');
const code = id => codes.get(id) ?? 'onbekend';
const physical = id => portals.get(id)?.physicalId ?? id;
const legs = new Map(candidate.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
const time = value => Date.parse(value) / 1000;
const iso = value => Number.isFinite(value) ? new Date(value * 1000).toISOString() : null;
const targets = ['P-02', 'P-12'].map(value => candidate.portals.find(portal => portal.code === value));
if (targets.some(target => !target || target.finale)) throw new Error('ORGANIZER_TARGET_MISSING');
const privateNames = [...production.portals, ...candidate.portals].filter(portal => portal.name && portal.name !== portal.code).map(portal => [portal.name, portal.code]).sort((a, b) => b[0].length - a[0].length);
function safeText(value) {
  let result = String(value ?? '');
  for (const [name, replacement] of privateNames) result = result.split(name).join(replacement);
  for (const [id, replacement] of codes) result = result.split(id).join(replacement);
  return result.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '[interne identificatie]')
    .replace(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/gi, '[e-mailadres]');
}
function cleanDiagnostic(diagnostic) {
  return { code: diagnostic.code, severity: diagnostic.severity, message: safeText(diagnostic.message),
    ...(diagnostic.groupId ? { groupCode: code(diagnostic.groupId) } : {}), ...(diagnostic.portalId ? { portalCode: code(diagnostic.portalId) } : {}) };
}
function uniqueDiagnostics(diagnostics) {
  return [...new Map(diagnostics.map(diagnostic => [JSON.stringify(diagnostic), diagnostic])).values()];
}
// An administrative gathering row remains in storage. The proposal validator
// takes physical visits numbered from one, so normalize only its local view.
const normalizedStored = production.before.map(plan => ({ ...plan, visits: plan.visits.filter(visit => visit.kind !== 'start').sort((a, b) => a.sequence - b.sequence).map((visit, index) => ({ ...visit, sequence: index + 1 })) }));
function targetCoverage(plans, target) {
  const covered = plans.filter(plan => plan.visits.some(visit => visit.kind === 'ordinary' && physical(visit.portalId) === physical(target.id))).map(plan => code(plan.groupId)).sort();
  return { portalCode: target.code, groups: covered.length, totalGroups: candidate.groups.length, coveredGroups: covered, missingGroups: candidate.groups.map(group => group.code).filter(value => !covered.includes(value)).sort() };
}
// A shortest walk with zero service at intermediate nodes is an optimistic
// lower bound. Exceeding a real closing time even under that assumption proves
// the visit cannot fit; passing this test does not establish joint feasibility.
function shortestWalk(start, destination) {
  const unsettled = new Set(candidate.legs.map(leg => leg.from)); unsettled.add(destination);
  const distances = new Map([[start, 0]]);
  while (unsettled.size) {
    let node = null, distance = Infinity;
    for (const item of unsettled) if ((distances.get(item) ?? Infinity) < distance) { node = item; distance = distances.get(item); }
    if (!node || node === destination) return distance;
    unsettled.delete(node);
    for (const leg of candidate.legs) if (leg.from === node && distance + leg.seconds < (distances.get(leg.to) ?? Infinity)) distances.set(leg.to, distance + leg.seconds);
  }
  return Infinity;
}
function targetWindowBound(group, target) {
  let earliest = time(group.startsAt), walking = 0;
  const first = portals.get(group.fixedFirstPortalId);
  if (first && physical(first.id) !== physical(target.id)) {
    const incoming = shortestWalk(group.startNodeId, first.nodeId);
    earliest = Math.min(...first.windows.map(window => Math.max(earliest + incoming, time(window.opensAt)) + window.visitSeconds));
    walking += incoming;
  }
  const remaining = shortestWalk(first && physical(first.id) !== physical(target.id) ? first.nodeId : group.startNodeId, target.nodeId);
  walking += remaining;
  earliest += remaining;
  const feasibleWindows = target.windows.map(window => ({ earliest: Math.max(earliest, time(window.opensAt)),
    // ArrivalClosesAt is exclusive for ordinary houses. In this snapshot the
    // buffer/physical closing is the stricter, inclusive bound.
    latest: Math.min(time(window.arrivalClosesAt) - 0.000001, time(window.closesAt) - window.visitSeconds - window.bufferSeconds, time(group.ordinaryStopAt) - window.visitSeconds) }));
  const last = Math.max(...feasibleWindows.map(window => window.latest));
  const impossible = !feasibleWindows.some(window => window.earliest <= window.latest);
  return { groupCode: group.code, portalCode: target.code, fixedFirstPortalCode: first?.code ?? null,
    optimisticArrivalAt: iso(Math.min(...feasibleWindows.map(window => window.earliest))), latestPossibleArrivalAt: iso(last),
    optimisticWalkingSeconds: walking, hardWindowConflictProven: impossible,
    explanation: impossible ? `Zelfs de optimistische loopondergrens${first && physical(first.id) !== physical(target.id) ? ` met het beschermde eerste bezoek aan ${first.code}` : ''} overschrijdt de laatste bruikbare ontvangst. Tussenliggende extra bezoeken en wachten kunnen dit niet herstellen.` : 'De onafhankelijke start/opening-ondergrens sluit dit bezoek niet uit. Dit is geen bewijs dat het in de gedeelde kalender past.' };
}
const targetBounds = candidate.groups.flatMap(group => targets.map(target => targetWindowBound(group, target))).sort((a, b) => a.groupCode.localeCompare(b.groupCode) || a.portalCode.localeCompare(b.portalCode));
const maximumHouseService = new Map();
for (const portal of candidate.portals.filter(portal => !portal.finale)) maximumHouseService.set(physical(portal.id), Math.max(maximumHouseService.get(physical(portal.id)) ?? 0, ...portal.windows.map(window => window.visitSeconds)));
const maximumOrdinaryVisitSeconds = [...maximumHouseService.values()].reduce((sum, seconds) => sum + seconds, 0);
const completionBounds = candidate.groups.map(group => {
  const finale = portals.get(group.finale.portalId), earliest = group.earliestCompletionAt ? time(group.earliestCompletionAt) : -Infinity;
  const latest = group.latestCompletionAt ? time(group.latestCompletionAt) : Infinity;
  const possible = finale.windows.some(window => Math.max(time(window.opensAt), time(group.startsAt), earliest - window.visitSeconds)
    <= Math.min(time(window.arrivalClosesAt), time(window.closesAt) - window.visitSeconds - window.bufferSeconds, time(group.finale.latestArrivalAt), latest - window.visitSeconds));
  const show = Math.max(...finale.windows.map(window => window.visitSeconds));
  return { groupCode: group.code, physicalFinaleAndEndWindowConflictProven: !possible,
    availableUniqueOrdinaryHouses: maximumHouseService.size, maximumOrdinaryVisitSeconds, maximumWalkingSeconds: candidate.maxTotalWalkingSeconds,
    maximumShowSeconds: show, minimumIdleSecondsBeforeEarliestCompletion: Number.isFinite(earliest)
      ? Math.max(0, earliest - time(group.startsAt) - maximumOrdinaryVisitSeconds - candidate.maxTotalWalkingSeconds - show) : 0,
    explanation: 'Conservatieve duurondergrens: zelfs alle echte unieke huizen met hun langste echte bezoekduur, het volledige loopbudget en de echte show vullen samen slechts een begrensde tijd. Een positief restant moet binnen dit eindvenster ontvangstwachttijd of vrije tijd zijn. Het bewijs veronderstelt geen verplichte omweg en bewijst niet dat alle huizen gezamenlijk passen.' };
}).sort((a, b) => a.groupCode.localeCompare(b.groupCode));

function cleanMetrics(input, plans) {
  const result = measureJointRoutes(input, plans);
  const groupMetrics = result.byGroup.map(metric => {
    const group = groups.get(metric.groupId), plan = plans.find(plan => plan.groupId === metric.groupId), completion = time(plan.expectedCompletionAt);
    const earliest = group.earliestCompletionAt ? time(group.earliestCompletionAt) : group.desiredEndAt ? time(group.desiredEndAt) - candidate.maxEarlyFinishSeconds : -Infinity;
    const latest = group.latestCompletionAt ? time(group.latestCompletionAt) : group.desiredEndAt ? time(group.desiredEndAt) + candidate.maxGroupOverrunSeconds : Infinity;
    return { groupCode: group.code, ordinaryVisits: metric.ordinaryVisits, walkingSeconds: metric.walkingSeconds,
      receptionWaitingSeconds: metric.receptionWaitingSeconds, freeBeforeFinaleSeconds: metric.unallocatedBeforeFinaleSeconds,
      longestWaitSeconds: metric.longestWaitSeconds, endDeviationSeconds: metric.endDeviationSeconds,
      finaleArrivalAt: metric.finaleArrivalAt, expectedCompletionAt: plan.expectedCompletionAt,
      earlyWindowViolationSeconds: Math.max(0, earliest - completion), lateWindowViolationSeconds: Math.max(0, completion - latest) };
  }).sort((a, b) => a.groupCode.localeCompare(b.groupCode));
  return { totalOrdinaryVisits: result.totalOrdinaryVisits, minOrdinaryVisits: result.minOrdinaryVisits, maxOrdinaryVisits: result.maxOrdinaryVisits,
    zeroVisitGroups: result.zeroVisitGroups, walkingSeconds: result.walkingSeconds, receptionWaitingSeconds: result.receptionWaitingSeconds,
    freeBeforeFinaleSeconds: result.unallocatedBeforeFinaleSeconds, longestWaitSeconds: result.longestWaitSeconds,
    absoluteEndDeviationSeconds: result.absoluteEndDeviationSeconds, overrunSeconds: result.overrunSeconds,
    endWindowViolations: groupMetrics.filter(group => group.earlyWindowViolationSeconds > 0 || group.lateWindowViolationSeconds > 0).length,
    unvisitedPortals: result.unvisitedPortals.map(code).sort(), coverage: targets.map(target => targetCoverage(plans, target)), byGroup: groupMetrics,
    byPortal: result.byPortal.map(portal => ({ portalCode: code(portal.portalId), visits: portal.visits,
      usableOpenSeconds: portal.usableOpenSeconds, firstArrivalAt: portal.firstArrivalAt, largestGapSeconds: portal.largestGapSeconds,
      explanation: portal.explanation ? safeText(portal.explanation) : null })).sort((a, b) => a.portalCode.localeCompare(b.portalCode)) };
}
function cleanPlan(plan) {
  const group = groups.get(plan.groupId);
  let node = group.startNodeId, cursor = time(group.startsAt);
  return { groupCode: group.code, startsAt: group.startsAt, desiredEndAt: group.desiredEndAt,
    earliestCompletionAt: group.earliestCompletionAt ?? null, latestCompletionAt: group.latestCompletionAt ?? null,
    ordinaryStopAt: group.ordinaryStopAt, startConfirmed: group.startConfirmed,
    fixedFirstPortalCode: group.fixedFirstPortalId ? code(group.fixedFirstPortalId) : null,
    previousFinaleArrivalAt: group.finale.reservedAt, finaleArrivalAt: plan.finaleArrivalAt, expectedCompletionAt: plan.expectedCompletionAt,
    finaleChange: plan.finaleChange ? { portalCode: code(plan.finaleChange.portalId), previousReservedAt: plan.finaleChange.previousReservedAt, proposedReservedAt: plan.finaleChange.proposedReservedAt } : null,
    visits: plan.visits.filter(visit => visit.kind !== 'start').sort((a, b) => a.sequence - b.sequence).map((visit, index) => {
      const portal = portals.get(visit.portalId), leg = legs.get(`${node}|${portal?.nodeId}`), wait = leg ? Math.max(0, time(visit.startsAt) - cursor - leg.seconds) : null;
      node = portal?.nodeId; cursor = time(visit.startsAt) + visit.visitSeconds;
      return { sequence: index + 1, portalCode: code(visit.portalId), kind: visit.kind, startsAt: visit.startsAt,
        visitSeconds: visit.visitSeconds, bufferSeconds: visit.bufferSeconds, walkSeconds: leg?.seconds ?? null, walkMeters: leg?.meters ?? null,
        receptionWaitingSeconds: visit.kind === 'ordinary' ? wait : 0, freeBeforeFinaleSeconds: visit.kind === 'finale' ? wait : 0 };
    }), diagnostics: uniqueDiagnostics((plan.diagnostics ?? []).map(cleanDiagnostic)) };
}

const variants = [{ key: 'stored', label: 'Opgeslagen bord · 60 minuten', targets: [], plans: normalizedStored,
  policyValid: validateJointRoutes(production, normalizedStored).length === 0, conflicts: validateJointRoutes(production, normalizedStored) }];
const modes = [{ key: 'general', label: '65 minuten · algemeen', targetCodes: [] },
  { key: 'p02', label: '65 minuten · P-02-doel', targetCodes: ['P-02'] },
  { key: 'p12', label: '65 minuten · P-12-doel', targetCodes: ['P-12'] },
  { key: 'p02-p12', label: '65 minuten · P-02 en P-12', targetCodes: ['P-02', 'P-12'] }];
for (const mode of modes) {
  const input = { ...candidate, organizerCoveragePortalIds: mode.targetCodes.length
    ? mode.targetCodes.map(value => targets.find(target => target.code === value).id) : candidate.organizerCoveragePortalIds };
  const started = performance.now(), proposal = proposeJointRoutes(input, { mode: mode.targetCodes.length ? 'organizer-coverage' : 'general' }), validation = validateJointRoutes(input, proposal.groups);
  variants.push({ key: mode.key, label: mode.label, targets: mode.targetCodes, plans: proposal.groups,
    policyValid: proposal.valid && validation.length === 0, conflicts: uniqueDiagnostics([...proposal.conflicts, ...validation]),
    proposalHash: proposal.proposalHash, calculationMilliseconds: Math.round(performance.now() - started), work: proposal.work });
  if (options['--private-output']) {
    await mkdir(options['--private-output'], { recursive: true, mode: 0o700 });
    await writeFile(join(options['--private-output'], `${mode.key}-proposal.json`), `${JSON.stringify(proposal, null, 2)}\n`, { mode: 0o600 });
  }
}
const reviewed = variants.map(variant => ({ key: variant.key, label: variant.label, organizerTargetCodes: variant.targets,
  localPolicyValid: variant.policyValid, originalProposalHash: variant.proposalHash ?? null,
  calculationMilliseconds: variant.calculationMilliseconds ?? null, work: variant.work ?? null,
  metrics: cleanMetrics(candidate, variant.plans), groups: variant.plans.map(cleanPlan).sort((a, b) => a.groupCode.localeCompare(b.groupCode)),
  hardConflicts: uniqueDiagnostics(variant.conflicts.filter(diagnostic => diagnostic.severity === 'block').map(cleanDiagnostic)),
  globalQualityAdvice: uniqueDiagnostics(variant.conflicts.filter(diagnostic => diagnostic.severity === 'warning' && !diagnostic.groupId).map(cleanDiagnostic)) }));
const source = { readAt: metadata.readAt, projectRef: 'dtubngvxfbupgvgfrjko', sourceHash: production.sourceHash,
  boardHash: production.boardHash, inputPolicyVersion: production.policyVersion, candidatePolicyVersion: candidate.policyVersion,
  plannerSourceSha256,
  activeGroups: candidate.groups.length, activePlanningPortals: candidate.portals.length, inventoryPortals: metadata.portalInventory?.length ?? null,
  activeChildren: metadata.activeChildren ?? null, childrenInPlanningGroups: candidate.groups.reduce((sum, group) => sum + group.childCount, 0), startedGroups: metadata.startedGroups,
  acceptedVersions: (metadata.acceptedVersions ?? []).map(version => ({ revision: version.revision, acceptedAt: version.acceptedAt, policyVersion: version.policyVersion })),
  latestReadOnlyProductionCheck: metadata.latestReadOnlyProductionCheck ?? null,
  comparisonHistory: metadata.comparisonHistory ?? null,
  requiresFreshInputAfterMigration: production.policyVersion !== candidate.policyVersion };
const explanation = `Lokaal beoordelingsrapport; geen route opgeslagen, toegepast, gepubliceerd of naar deelnemers verstuurd. Het bord met ${reviewed[0].metrics.totalOrdinaryVisits} bezoeken is werkelijk geaccepteerd. De vier nieuwe varianten gebruiken expliciet kandidaatbeleid v3 (65 minuten lopen, voorgestelde vroegtetolerantie 30 minuten) op dezelfde actuele v2-productiesnapshot. Oude bronhashen zijn niet aangepast; deze bestanden zijn geen toepasbare routecommando’s. Na ingebruikname van v3 is verse gezaghebbende RPC-invoer en herberekening nodig. De begrensde deterministische zoekroutine bewijst geen wereldwijd optimum. Een niet gevonden bezoek is uitsluitend bewezen onmogelijk wanneer de afzonderlijke gecontroleerde ondergrens dat aantoont.`;
const inventory = (metadata.portalInventory ?? []).map(portal => ({ portalCode: portal.code, approvalStatus: portal.approvalStatus,
  lifecycleStatus: portal.lifecycleStatus, operationStatus: portal.operationStatus, locationReady: portal.locationReady,
  createdAt: portal.createdAt, updatedAt: portal.updatedAt, version: portal.version,
  effectiveWindows: (portal.effectiveWindows ?? []).map(window => ({ opensAt: window.opens_at, arrivalClosesAt: window.arrival_closes_at,
    closesAt: window.closes_at, visitSeconds: window.visit_seconds, bufferSeconds: window.buffer_seconds,
    maxGroups: window.max_groups, headwaySeconds: window.headway_seconds, maxChildren: window.max_children,
    maxTotalChildren: window.max_total_children, maxConcurrentChildren: window.max_concurrent_children })) }));
const summary = { artifactType: 'joint-route-65-coverage-review', generatedAt: new Date().toISOString(), timeZone: 'Europe/Amsterdam',
  applicableToDatabase: false, applied: false, published: false, participantsMessaged: false, explanation, source,
  policy: { maxTotalWalkingSeconds: candidate.maxTotalWalkingSeconds, maxOrdinaryLegWalkingSeconds: candidate.maxLegWalkingSeconds,
    finaleLegLimitSeconds: null, maxEarlyFinishSeconds: candidate.maxEarlyFinishSeconds, maxOverrunSeconds: candidate.maxGroupOverrunSeconds,
    earlyFinishStandardIsNewProposal: true, routePolicySettingsVersion: candidate.routePolicySettingsVersion },
  searchLimits: JOINT_ROUTE_SEARCH_LIMITS, targetWindows: targets.map(target => ({ portalCode: target.code, accessibilityStatus: target.accessibilityStatus, windows: target.windows })),
  independentTargetWindowBounds: targetBounds, independentCompletionBounds: completionBounds, portalInventory: inventory,
  variants: reviewed.map(variant => Object.fromEntries(Object.entries(variant).filter(([name]) => name !== 'groups'))) };
const reviewProposal = { artifactType: 'coded-review-only', applicableToDatabase: false, explanation, source, variants: reviewed };

const escape = value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
const localDateTime = value => new Intl.DateTimeFormat('nl-NL', { timeZone: 'Europe/Amsterdam', dateStyle: 'short', timeStyle: 'medium' }).format(new Date(value));
const clock = value => value ? new Intl.DateTimeFormat('nl-NL', { timeZone: 'Europe/Amsterdam', hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date(value)) : '—';
const minutes = value => Number.isFinite(value) ? new Intl.NumberFormat('nl-NL', { maximumFractionDigits: 1 }).format(value / 60) : '—';
const duration = value => Number.isFinite(value) ? `${Math.floor(Math.round(value) / 60)}:${String(Math.round(value) % 60).padStart(2, '0')}` : '—';
const table = (headers, rows) => `<div class="table"><table><thead><tr>${headers.map(header => `<th>${escape(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
const diagnostics = items => items.length ? `<ul>${uniqueDiagnostics(items).map(item => `<li>${item.groupCode ? `${escape(item.groupCode)} · ` : ''}${item.portalCode ? `${escape(item.portalCode)} · ` : ''}${escape(item.message)}</li>`).join('')}</ul>` : '<p>Geen.</p>';
const metricsRows = [
  ['Echte unieke gewone bezoeken', metric => metric.totalOrdinaryVisits], ['Bezoeken per groep', metric => `${metric.minOrdinaryVisits}–${metric.maxOrdinaryVisits}`],
  ['Werkelijk lopen, totaal min', metric => minutes(metric.walkingSeconds)], ['Ontvangstwachten, totaal min', metric => minutes(metric.receptionWaitingSeconds)],
  ['Vrij vóór P-38, totaal min', metric => minutes(metric.freeBeforeFinaleSeconds)], ['Langste afzonderlijke wachttijd', metric => duration(metric.longestWaitSeconds)],
  ['Afwijkingen nieuw eindvenster', metric => metric.endWindowViolations], ['P-02 bezocht door groepen', metric => `${metric.coverage[0].groups}/${candidate.groups.length}`],
  ['P-12 bezocht door groepen', metric => `${metric.coverage[1].groups}/${candidate.groups.length}`], ['Huizen zonder bezoek', metric => metric.unvisitedPortals.join(', ') || 'Geen'],
].map(([label, value]) => [escape(label), ...reviewed.map(variant => escape(value(variant.metrics)))]);
const groupRows = candidate.groups.slice().sort((a, b) => a.code.localeCompare(b.code)).map(group => [escape(group.code), clock(group.startsAt), clock(group.desiredEndAt), `${clock(group.earliestCompletionAt)}–${clock(group.latestCompletionAt)}`,
  ...reviewed.map(variant => { const metric = variant.metrics.byGroup.find(item => item.groupCode === group.code); return `${metric.ordinaryVisits} huizen<br>P-38 ${clock(metric.finaleArrivalAt)}<br>klaar ${clock(metric.expectedCompletionAt)}${metric.earlyWindowViolationSeconds > 0 ? `<br><strong>${duration(metric.earlyWindowViolationSeconds)} vóór ondergrens</strong>` : ''}`; })]);
const coverageDetails = reviewed.map(variant => `<h3>${escape(variant.label)}</h3>${table(['Huis', 'Bezocht', 'Ontbrekend', 'Controleerbare verklaring'], variant.metrics.coverage.map(target => [escape(target.portalCode), `${target.groups}/${target.totalGroups}`, escape(target.missingGroups.join(', ') || 'Geen'), target.missingGroups.map(groupCode => { const bound = targetBounds.find(item => item.groupCode === groupCode && item.portalCode === target.portalCode); return `<p><strong>${escape(groupCode)}:</strong> ${bound.hardWindowConflictProven ? `optimistische aankomst ${clock(bound.optimisticArrivalAt)} na laatste bruikbare ontvangst ${clock(bound.latestPossibleArrivalAt)}. ${escape(bound.explanation)}` : 'In deze begrensde variant niet gevonden; de onafhankelijke start/opening-ondergrens bewijst geen onmogelijkheid. Zie de route voor de bijbehorende invoegdiagnose.'}</p>`; }).join('') || 'Alle groepen opgenomen.']))}`).join('');
const routeDetails = reviewed.map(variant => `<details><summary>${escape(variant.label)} · ${variant.metrics.totalOrdinaryVisits} bezoeken · ${variant.localPolicyValid ? 'geen harde conflicten onder eigen beleid' : 'harde conflicten'}</summary>${diagnostics(variant.hardConflicts)}${variant.groups.map(plan => {
  const metric = variant.metrics.byGroup.find(item => item.groupCode === plan.groupCode);
  return `<details><summary>${escape(plan.groupCode)} · ${metric.ordinaryVisits} huizen · klaar ${clock(plan.expectedCompletionAt)}</summary><p>Vaste start ${clock(plan.startsAt)}; gekoppeld eerste huis ${escape(plan.fixedFirstPortalCode ?? 'geen')}; gewone eindgrens ${clock(plan.ordinaryStopAt)}. Gewenst klaar ${clock(plan.desiredEndAt)}; nieuw eindvenster ${clock(plan.earliestCompletionAt)}–${clock(plan.latestCompletionAt)}.</p><p>Werkelijk lopen ${minutes(metric.walkingSeconds)} min; ontvangstwachttijd ${minutes(metric.receptionWaitingSeconds)} min; vrije tijd vóór P-38 ${minutes(metric.freeBeforeFinaleSeconds)} min; langste afzonderlijke wachttijd ${duration(metric.longestWaitSeconds)}. P-38 ${clock(plan.previousFinaleArrivalAt)} → ${clock(plan.finaleArrivalAt)}; show klaar ${clock(plan.expectedCompletionAt)}.</p>${table(['#', 'Huis', 'Aankomst', 'Lopen', 'Ontvangstwachten', 'Vrij vóór P-38', 'Bezoek/show', 'Buffer'], plan.visits.map(visit => [visit.sequence, escape(visit.portalCode), clock(visit.startsAt), duration(visit.walkSeconds), duration(visit.receptionWaitingSeconds), duration(visit.freeBeforeFinaleSeconds), duration(visit.visitSeconds), duration(visit.bufferSeconds)]))}<h4>Harde conflicten</h4>${diagnostics(plan.diagnostics.filter(item => item.severity === 'block'))}<h4>Kwaliteitsadviezen en concrete invoegdiagnoses</h4>${diagnostics(plan.diagnostics.filter(item => item.severity === 'warning'))}</details>`;
}).join('')}</details>`).join('');
const windowRows = targets.flatMap(target => target.windows.map(window => [escape(target.code), `${clock(window.opensAt)}–${clock(window.closesAt)}`, clock(window.arrivalClosesAt),
  clock(iso(Math.min(time(window.arrivalClosesAt) - 0.000001, time(window.closesAt) - window.visitSeconds - window.bufferSeconds))), duration(window.visitSeconds), duration(window.bufferSeconds), window.maxGroups, duration(window.headwaySeconds), window.maxChildren, window.maxConcurrentChildren ?? 'geen aparte limiet']));
const idleProofRows = completionBounds.filter(bound => bound.minimumIdleSecondsBeforeEarliestCompletion > 0).map(bound => [escape(bound.groupCode), bound.availableUniqueOrdinaryHouses,
  minutes(bound.maximumOrdinaryVisitSeconds), minutes(bound.maximumWalkingSeconds), minutes(bound.maximumShowSeconds), minutes(bound.minimumIdleSecondsBeforeEarliestCompletion)]);
const idleProofHtml = `<h3>Eerlijke duurafweging</h3><p>${completionBounds.some(bound => bound.physicalFinaleAndEndWindowConflictProven) ? 'Er zijn harde conflicten tussen het persoonlijke eindvenster en de fysieke finaleopening; zie de JSON-diagnoses.' : 'Geen persoonlijk eindvenster is op zichzelf strijdig met de fysieke opening en showduur van P-38. Dit bewijst nog geen volledige gezamenlijke route.'} De beschikbare echte bezoeken begrenzen hoeveel actieve tijd de avond kan bevatten. Onderstaande conservatieve ondergrens blijft bestaan zelfs als alle huizen passen en het volledige loopbudget wordt benut.</p>${table(['Groep', 'Echte unieke huizen', 'Maximale echte bezoektijd min', 'Loopbudget min', 'Show min', 'Minimaal wachten/vrij min'], idleProofRows)}<p class="fine">De loopduur is een bovengrens in dit bewijs, geen opdracht om omwegen te lopen. Ontvangstbuffers zijn fysieke ontvangstbezetting en worden niet als fictieve extra bezoektijd opgeteld. Een nieuwe actieve poort verandert deze duurafweging pas met haar werkelijke bezoekduur.</p>`;
const inventoryHtml = `<h3>Alle poorten in de actuele snapshot</h3>${table(['Poort', 'Goedkeuring', 'Levensfase', 'Ontvangststatus', 'Locatie gereed', 'Plannerkandidaat', 'Effectieve ontvangst'], inventory.map(portal => [escape(portal.portalCode), escape(portal.approvalStatus), escape(portal.lifecycleStatus), escape(portal.operationStatus), portal.locationReady ? 'Ja' : 'Nee', candidate.portals.some(item => item.code === portal.portalCode) ? 'Ja' : 'Nee', portal.effectiveWindows.map(window => `${clock(window.opensAt)}–${clock(window.closesAt)}`).join('<br>') || 'Geen']))}<p class="fine">Een conceptpoort is pas kandidaat na werkelijke goedkeuring en activering. Dit rapport wijzigt die status niet.</p>`;
const html = `<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>65 minuten en huisdekking · routebeoordeling</title><style>*{box-sizing:border-box}body{font:16px/1.55 system-ui,sans-serif;color:#203135;background:#f3f5f4;margin:0}header{background:#163337;color:white;padding:30px max(20px,calc((100vw - 1440px)/2))}main{max-width:1480px;margin:auto;padding:20px}section,details{background:white;border:1px solid #d5dfdc;border-radius:9px;padding:20px;margin:18px 0}.notice{border-left:5px solid #bf6a15;background:#fff1da;padding:18px}h1{font-size:clamp(26px,4vw,40px)}h2{font-size:24px}h3{font-size:19px}.table{overflow:auto}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:9px;border-bottom:1px solid #d5dfdc;text-align:left;vertical-align:top;font-variant-numeric:tabular-nums}th{background:#eef4f2}td{min-width:105px}summary{cursor:pointer;font-weight:700}code{overflow-wrap:anywhere}a{color:#9b430d}nav{display:flex;gap:22px;flex-wrap:wrap}.fine{font-size:13px;color:#526762}@media print{details{break-inside:avoid}body{background:white}.table{overflow:visible}}</style></head><body><header><p>31 oktober 2026 · De Duindorpse Poorten van Halloween</p><h1>65 minuten lopen en echte huisdekking</h1><p>Opgeslagen planning tegenover algemeen routebeleid en expliciete organisatiedoelen voor P-02 en P-12.</p></header><main><p class="notice"><strong>Alleen ter beoordeling.</strong> ${escape(explanation)}</p><nav><a href="#compare">Vergelijking</a><a href="#windows">Echte vensters</a><a href="#groups">Groepen</a><a href="#coverage">Dekking en bewijs</a><a href="#routes">Routes</a><a href="#source">Bronnen</a></nav><section id="compare"><h2>Vijf verschillende planningsstanden</h2><p>Het opgeslagen bord valt onder het bestaande 60-minutenbeleid zonder vroegteondergrens. De nieuwe varianten toetsen het einde van de werkelijke show aan gewenst einde min 30 minuten en plus de bestaande uitloop. Alleen een later finaleslot voegt geen huisbezoek toe.</p>${table(['Vergelijking', ...reviewed.map(variant => variant.label)], metricsRows)}<p class="fine">Alle tijden in Europe/Amsterdam. Minuten afgerond op één decimaal. Ontvangstwachten en vrije tijd vóór P-38 staan apart; de langste wachttijd omvat ook het afzonderlijke gat vóór de finale. Een organisatiedoel is een afzonderlijk beoordeelde prioriteit voor concrete huizen, geen thema- of wereldvoorkeur.</p></section><section id="windows"><h2>Actuele ontvangst bij P-02 en P-12</h2>${table(['Huis', 'Effectief open', 'Laatste aankomstlabel', 'Laatste aankomst met buffer', 'Bezoek', 'Buffer', 'Gelijktijdige groepen', 'Aankomstafstand', 'Kinderen per groep', 'Gelijktijdige kinderen'], windowRows)}<p>De sluiting omvat de ontvangstbuffer. De kolom “laatste aankomst met buffer” toont daarom de werkelijk bruikbare grens, die eerder kan liggen dan het aankomstlabel. De persoonlijke en globale gewone eindgrenzen kunnen de ontvangst nog verder beperken. Capaciteitsgetallen zijn de werkelijk aangeleverde waarden.</p>${idleProofHtml}${inventoryHtml}</section><section id="groups"><h2>Start, eindvenster en finale per groep</h2>${table(['Groep', 'Vaste start', 'Gewenst klaar', 'Nieuw toegestaan showeinde', ...reviewed.map(variant => variant.label)], groupRows)}</section><section id="coverage"><h2>Welke groepen missen de twee huizen?</h2><p>Een harde openingsdiagnose is gebaseerd op een optimistische kortste wandeling door de gehele invoergraaf, zonder extra bezoektijd op tussenpunten. Waar van toepassing telt het beschermde eerste huis wel met zijn echte bezoekduur mee. Als zelfs deze ondergrens te laat is, kunnen extra stops of wachten de route niet herstellen. Een geslaagde ondergrenstoets bewijst geen gezamenlijke inpasbaarheid.</p>${coverageDetails}</section><section id="routes"><h2>Werkelijke routes en samengekoppelde diagnoses</h2><p>Open een variant en groep voor alle fysieke etappes, ontvangstwachttijd, vrije tijd en concrete invoegdiagnoses. Administratief verzamelen is apart bewaard en telt niet als huisbezoek. Geen fictieve stop, extra rondje of verlengde show is toegevoegd.</p>${routeDetails}</section><section id="source"><h2>Bronnen en herhaalbaarheid</h2><p>Productiesnapshot ${escape(localDateTime(source.readAt))} Nederlandse tijd. ${source.activeGroups} groepen, ${source.activePlanningPortals} actieve geschikte poorten, ${source.inventoryPortals} totale poortrecords; ${source.activeChildren} actieve evenementkinderen, waarvan ${source.childrenInPlanningGroups} in de routegroepen; ${source.startedGroups} begonnen groepen.</p><p>Bronhash <code>${escape(source.sourceHash)}</code><br>Bordhash <code>${escape(source.boardHash)}</code><br>Plannerbron SHA-256 <code>${escape(source.plannerSourceSha256)}</code><br>Invoer ${escape(source.inputPolicyVersion)}; lokaal kandidaatbeleid ${escape(source.candidatePolicyVersion)}.</p><p>De opgeslagen planning is geaccepteerd op ${escape(source.acceptedVersions.map(version => localDateTime(version.acceptedAt)).join(', '))} Nederlandse tijd. Een toekomstige poort wordt pas meegenomen zodra die bij een verse controle werkelijk actief, goedgekeurd, locatiegereed en voorzien van bruikbare ontvangstvensters is.</p><p class="fine">Begrensde deterministische berekening. Geen bewijs van een wereldwijd optimum. Huisnamen, personen, adressen, coördinaten en interne UUID’s ontbreken. De herhaalbare runner leest uitsluitend lokale JSON-bestanden en schrijft deze beoordelingsbestanden.</p><p><a href="summary.json">Vergelijking JSON</a> · <a href="proposal.json">Gecodeerde routes JSON</a> · <a href="comparison.csv">Groepsvergelijking CSV</a></p></section></main></body></html>`;
const csvCell = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
const csv = [['variant', 'group', 'start_local', 'desired_end_local', 'earliest_completion_local', 'latest_completion_local', 'ordinary_visits', 'walking_seconds', 'reception_waiting_seconds', 'free_before_finale_seconds', 'longest_wait_seconds', 'p38_reserved_local', 'p38_proposed_local', 'completion_local', 'early_window_violation_seconds', 'late_window_violation_seconds', 'p02_visited', 'p12_visited']];
for (const variant of reviewed) for (const plan of variant.groups) { const metric = variant.metrics.byGroup.find(item => item.groupCode === plan.groupCode); csv.push([variant.key, plan.groupCode, clock(plan.startsAt), clock(plan.desiredEndAt), clock(plan.earliestCompletionAt), clock(plan.latestCompletionAt), metric.ordinaryVisits, metric.walkingSeconds, metric.receptionWaitingSeconds, metric.freeBeforeFinaleSeconds, metric.longestWaitSeconds, clock(plan.previousFinaleArrivalAt), clock(plan.finaleArrivalAt), clock(plan.expectedCompletionAt), metric.earlyWindowViolationSeconds, metric.lateWindowViolationSeconds, plan.visits.some(visit => visit.portalCode === 'P-02'), plan.visits.some(visit => visit.portalCode === 'P-12')]); }
const files = { 'review.html': html, 'summary.json': `${JSON.stringify(summary, null, 2)}\n`, 'proposal.json': `${JSON.stringify(reviewProposal, null, 2)}\n`, 'comparison.csv': `\uFEFF${csv.map(row => row.map(csvCell).join(',')).join('\r\n')}\r\n` };
if (createHash('sha256').update(await readFile(plannerSourceFile)).digest('hex') !== plannerSourceSha256) throw new Error('PLANNER_SOURCE_CHANGED_DURING_REVIEW');
for (const [name, content] of Object.entries(files)) if (privateNames.some(([privateName]) => content.includes(privateName)) || /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i.test(content)) throw new Error(`PRIVATE_IDENTIFIER_IN_REPORT: ${name}`);
await mkdir(options['--output'], { recursive: true });
for (const [name, content] of Object.entries(files)) await writeFile(join(options['--output'], name), content);
console.log(JSON.stringify({ status: 'local-review-only', output: options['--output'], source,
  variants: reviewed.map(variant => ({ key: variant.key, valid: variant.localPolicyValid, visits: variant.metrics.totalOrdinaryVisits, coverage: variant.metrics.coverage.map(target => ({ portal: target.portalCode, groups: target.groups })), waitingSeconds: variant.metrics.receptionWaitingSeconds, freeSeconds: variant.metrics.freeBeforeFinaleSeconds, calculationMilliseconds: variant.calculationMilliseconds })) }, null, 2));
