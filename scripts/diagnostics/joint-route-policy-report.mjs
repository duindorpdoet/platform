#!/usr/bin/env node
/**
 * Local, read-only planning review. Requires Node 24's TypeScript stripping.
 * Reads private JSON files; writes only allowlisted review artifacts. No network,
 * database client, route apply command, publication or messaging is involved.
 *
 * node scripts/diagnostics/joint-route-policy-report.mjs \
 *   --input /tmp/duindorp-planner-input.json \
 *   --baseline /tmp/duindorp-planner-baseline-proposal.json \
 *   --output docs/reports/2026-10-30-joint-route-policy
 */
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { JOINT_ROUTE_SEARCH_LIMITS, measureJointRoutes, proposeJointRoutes, validateJointRoutes } from '../../lib/domain/joint-route-planner.ts';

const args = process.argv.slice(2), options = {};
for (let index = 0; index < args.length; index++) {
  const name = args[index];
  if (name === '--help') {
    console.log('Gebruik: node scripts/diagnostics/joint-route-policy-report.mjs --input <private-input.json> --baseline <old-proposal.json> --output <directory> [--metadata <snapshot-metadata.json>]');
    process.exit(0);
  }
  if (!['--input', '--baseline', '--output', '--metadata'].includes(name) || !args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`Onbekend of onvolledig argument: ${name}`);
  if (options[name.slice(2)]) throw new Error(`Dubbel argument: ${name}`);
  options[name.slice(2)] = resolve(args[++index]);
}
if (!options.input || !options.baseline || !options.output) throw new Error('--input, --baseline en --output zijn verplicht; gebruik --help.');
const input = JSON.parse(await readFile(options.input, 'utf8'));
const baseline = JSON.parse(await readFile(options.baseline, 'utf8'));
if (baseline.sourceHash !== input.sourceHash || baseline.boardHash !== input.boardHash) throw new Error('BASIS_HASH_MISMATCH: het oude voorstel en de invoer hebben niet dezelfde bron en hetzelfde bord.');
const metadataPath = options.metadata ?? join(dirname(options.input), 'duindorp-planner-metadata.json');
let metadata = null;
try { metadata = JSON.parse(await readFile(metadataPath, 'utf8')); } catch (error) { if (error.code !== 'ENOENT' || options.metadata) throw error; }
if (metadata && (metadata.sourceHash !== input.sourceHash || metadata.boardHash !== input.boardHash)) throw new Error('SNAPSHOT_METADATA_HASH_MISMATCH');

// Project only known codes, times and planning quantities. Never serialize the
// source object: portal names, coordinates and participant data stay private.
const groupCodes = new Map(input.groups.map(group => {
  if (!/^G-\d+$/.test(group.code)) throw new Error('GROUP_CODE_REQUIRED');
  return [group.id, group.code];
}));
const portalCodes = new Map(input.portals.map(portal => {
  if (!/^P-\d+$/.test(portal.code)) throw new Error('PORTAL_CODE_REQUIRED');
  return [portal.id, portal.code];
}));
const groupCode = id => groupCodes.get(id) ?? 'onbekende-groep';
const portalCode = id => portalCodes.get(id) ?? 'onbekende-poort';
const knownPrivateNames = input.portals.filter(portal => portal.name && portal.name !== portal.code).map(portal => [portal.name, portal.code]).sort((a, b) => b[0].length - a[0].length);
function safeText(value) {
  let text = String(value ?? '');
  for (const [name, code] of knownPrivateNames) text = text.split(name).join(code);
  for (const [id, code] of [...groupCodes, ...portalCodes]) text = text.split(id).join(code);
  return text.replace(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/gi, '[e-mailadres weggelaten]')
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '[interne identificatie weggelaten]');
}
const cleanDiagnostic = diagnostic => ({ code: diagnostic.code, severity: diagnostic.severity,
  ...(diagnostic.groupId ? { groupCode: groupCode(diagnostic.groupId) } : {}),
  ...(diagnostic.portalId ? { portalCode: portalCode(diagnostic.portalId) } : {}), message: safeText(diagnostic.message) });
const instant = value => Date.parse(value) / 1000;
const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
const portalById = new Map(input.portals.map(portal => [portal.id, portal]));
const groupById = new Map(input.groups.map(group => [group.id, group]));
const started = performance.now();
const proposal = proposeJointRoutes(input);
const calculationMilliseconds = Math.round(performance.now() - started);
const validation = validateJointRoutes(input, proposal.groups);
const measured = { storedBoard: measureJointRoutes(input, input.before), oldCalculated: measureJointRoutes(input, baseline.groups), newCalculated: measureJointRoutes(input, proposal.groups) };

function cleanMetrics(metrics) {
  return {
    groups: metrics.groups, totalOrdinaryVisits: metrics.totalOrdinaryVisits, minOrdinaryVisits: metrics.minOrdinaryVisits,
    meanOrdinaryVisits: metrics.meanOrdinaryVisits, maxOrdinaryVisits: metrics.maxOrdinaryVisits, zeroVisitGroups: metrics.zeroVisitGroups,
    walkingSeconds: metrics.walkingSeconds, waitingSeconds: metrics.waitingSeconds, receptionWaitingSeconds: metrics.receptionWaitingSeconds,
    unallocatedBeforeFinaleSeconds: metrics.unallocatedBeforeFinaleSeconds, longestWaitSeconds: metrics.longestWaitSeconds,
    absoluteEndDeviationSeconds: metrics.absoluteEndDeviationSeconds, overrunSeconds: metrics.overrunSeconds,
    administrativeStarts: metrics.administrativeStarts, unvisitedPortals: metrics.unvisitedPortals.map(portalCode).sort(),
    byGroup: metrics.byGroup.map(group => ({ groupCode: groupCode(group.groupId), ordinaryVisits: group.ordinaryVisits,
      walkingSeconds: group.walkingSeconds, receptionWaitingSeconds: group.receptionWaitingSeconds,
      unallocatedBeforeFinaleSeconds: group.unallocatedBeforeFinaleSeconds, longestWaitSeconds: group.longestWaitSeconds,
      endDeviationSeconds: group.endDeviationSeconds, finaleArrivalAt: group.finaleArrivalAt })).sort((a, b) => a.groupCode.localeCompare(b.groupCode)),
    byPortal: metrics.byPortal.map(portal => ({ portalCode: portalCode(portal.portalId), visits: portal.visits,
      usableOpenSeconds: portal.usableOpenSeconds, visitsPerOpenHour: portal.visitsPerOpenHour,
      firstArrivalAt: portal.firstArrivalAt, firstDelaySeconds: portal.firstDelaySeconds, largestGapSeconds: portal.largestGapSeconds,
      quarterHourBuckets: portal.quarterHourBuckets.map(bucket => ({ startsAt: bucket.startsAt, visits: bucket.visits })),
      explanation: portal.explanation ? safeText(portal.explanation) : null })).sort((a, b) => a.portalCode.localeCompare(b.portalCode)) };
}
function cleanPlan(plan) {
  const group = groupById.get(plan.groupId);
  let node = group.startNodeId, cursor = instant(group.startsAt);
  const visits = plan.visits.filter(visit => visit.kind !== 'start').sort((a, b) => a.sequence - b.sequence).map(visit => {
    const portal = portalById.get(visit.portalId), leg = legs.get(`${node}|${portal?.nodeId}`);
    const waitSeconds = leg ? Math.max(0, instant(visit.startsAt) - cursor - leg.seconds) : null;
    node = portal?.nodeId; cursor = instant(visit.startsAt) + visit.visitSeconds;
    return { sequence: visit.sequence, portalCode: portalCode(visit.portalId), kind: visit.kind, startsAt: visit.startsAt,
      visitSeconds: visit.visitSeconds, bufferSeconds: visit.bufferSeconds, walkSeconds: leg?.seconds ?? null, walkMeters: leg?.meters ?? null,
      receptionWaitingSeconds: visit.kind === 'ordinary' ? waitSeconds : 0, freeBeforeFinaleSeconds: visit.kind === 'finale' ? waitSeconds : 0 };
  });
  return { groupCode: groupCode(plan.groupId), startsAt: plan.startsAt, startConfirmed: group.startConfirmed,
    linkedFirstPortalCode: group.fixedFirstPortalId ? portalCode(group.fixedFirstPortalId) : null,
    ordinaryStopAt: group.ordinaryStopAt, desiredEndAt: group.desiredEndAt, latestFinaleArrivalAt: group.finale.latestArrivalAt,
    finaleArrivalAt: plan.finaleArrivalAt, expectedCompletionAt: plan.expectedCompletionAt,
    finaleChange: plan.finaleChange ? { portalCode: portalCode(plan.finaleChange.portalId), previousReservedAt: plan.finaleChange.previousReservedAt,
      proposedReservedAt: plan.finaleChange.proposedReservedAt } : null,
    visits, diagnostics: plan.diagnostics.map(cleanDiagnostic) };
}
const source = { snapshotReadAt: metadata?.readAt ?? null, localInputModifiedAt: (await stat(options.input)).mtime.toISOString(),
  sourceHash: input.sourceHash, boardHash: input.boardHash, inputPolicyVersion: input.policyVersion,
  candidatePolicyVersion: 'joint-reception-v2', requiresFreshInputAfterMigration: input.policyVersion !== 'joint-reception-v2',
  latestReadOnlyProductionCheck: metadata?.latestReadOnlyProductionCheck ? {
    readAt: metadata.latestReadOnlyProductionCheck.readAt,
    sourceHash: metadata.latestReadOnlyProductionCheck.sourceHash,
    boardHash: metadata.latestReadOnlyProductionCheck.boardHash,
    unchangedFromSnapshot: metadata.latestReadOnlyProductionCheck.unchangedFromSnapshot,
    jointVersions: metadata.latestReadOnlyProductionCheck.jointVersions,
    startedGroups: metadata.latestReadOnlyProductionCheck.startedGroups,
  } : null,
  comparisonHistory: metadata?.comparisonHistory ? {
    previousSnapshotReadAt: metadata.comparisonHistory.previousSnapshotReadAt,
    previousBoardHash: metadata.comparisonHistory.previousBoardHash,
    currentSnapshotReadAt: metadata.comparisonHistory.currentSnapshotReadAt,
    currentBoardHash: metadata.comparisonHistory.currentBoardHash,
    sourceHashUnchanged: metadata.comparisonHistory.sourceHashUnchanged,
    planningInputEqualExceptBoardHash: metadata.comparisonHistory.planningInputEqualExceptBoardHash,
    storedPlansUnchanged: metadata.comparisonHistory.storedPlansUnchanged,
    oldCalculatedRoutesUnchanged: metadata.comparisonHistory.oldCalculatedRoutesUnchanged,
    historicalOldCalculatedVisits: metadata.comparisonHistory.historicalOldCalculatedVisits,
    currentOldCalculatedVisits: metadata.comparisonHistory.currentOldCalculatedVisits,
    explanation: safeText(metadata.comparisonHistory.explanation),
  } : null,
  productionTreeAtInvestigation: 'db5dbe2d9cd75de4b98601f570141f96bdec8042',
  oldPlannerBlob: '9a7bdbd9db065ec90d9cb50f2a33b97a0d048051',
  plannerSourceSha256: createHash('sha256').update(await readFile(fileURLToPath(new URL('../../lib/domain/joint-route-planner.ts', import.meta.url)))).digest('hex') };
const explanation = `Lokaal berekend beoordelingsvoorstel. Niet opgeslagen in de database, niet toegepast, niet gepubliceerd en niet naar deelnemers verzonden. Het oude voorstel was eveneens berekend; het is niet het opgeslagen planbord. De begrensde deterministische zoektocht bewijst geen wereldwijd optimum. Kandidaatbeleid joint-reception-v2 is lokaal doorgerekend op de productiesnapshot met invoerbeleid ${input.policyVersion}. De v2-migratie wijzigt de bronhash; na ingebruikname moeten actuele invoer en een nieuw voorstel opnieuw worden berekend. Dit rapport is niet toepasbaar als routecommando.${source.comparisonHistory ? ` Na een wijziging van de bredere bordhash is een verse invoersnapshot opgehaald en zijn beide planners opnieuw berekend. Het historische oude voorstel met ${source.comparisonHistory.historicalOldCalculatedVisits} bezoeken is behouden; dezelfde oude planner geeft op het actuele bord opnieuw ${source.comparisonHistory.currentOldCalculatedVisits} bezoeken. ${source.comparisonHistory.explanation}` : ''}`;
const reviewGroups = proposal.groups.map(cleanPlan).sort((a, b) => a.groupCode.localeCompare(b.groupCode));
const metrics = Object.fromEntries(Object.entries(measured).map(([name, value]) => [name, cleanMetrics(value)]));
const diagnostics = proposal.conflicts.map(cleanDiagnostic);
const summary = { artifactType: 'joint-route-policy-review', generatedAt: new Date().toISOString(), timeZone: 'Europe/Amsterdam',
  status: 'local-review-only', applied: false, published: false, participantsMessaged: false, explanation, source,
  originalProposalHash: proposal.proposalHash, localPolicyValid: proposal.valid, validationConflicts: validation.map(cleanDiagnostic),
  calculationMilliseconds, searchLimits: JOINT_ROUTE_SEARCH_LIMITS, work: proposal.work, walkingPolicy: proposal.walkingPolicy,
  metrics, finaleChanges: reviewGroups.filter(group => group.finaleChange).map(group => ({ groupCode: group.groupCode, ...group.finaleChange,
    expectedCompletionAt: group.expectedCompletionAt })), hardConflicts: diagnostics.filter(diagnostic => diagnostic.severity === 'block'),
  qualityAdvice: diagnostics.filter(diagnostic => diagnostic.severity === 'warning') };
const reviewProposal = { artifactType: 'joint-route-review-only', applicableToDatabase: false,
  explanation: 'Alle interne groep- en poortidentificaties zijn vervangen door codes. Dit bestand is uitsluitend voor beoordeling en kan niet als toepasbaar routecommando worden gebruikt.',
  source, originalProposalHash: proposal.proposalHash, localPolicyValid: proposal.valid, walkingPolicy: proposal.walkingPolicy,
  groups: reviewGroups, hardConflicts: summary.hardConflicts, globalQualityAdvice: summary.qualityAdvice.filter(diagnostic => !diagnostic.groupCode) };

const htmlEscape = value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
const minutes = seconds => Number.isFinite(seconds) ? new Intl.NumberFormat('nl-NL', { maximumFractionDigits: 1 }).format(seconds / 60) : '—';
const duration = seconds => Number.isFinite(seconds) ? `${Math.floor(Math.round(seconds) / 60)}:${String(Math.round(seconds) % 60).padStart(2, '0')}` : '—';
const clock = value => value ? new Intl.DateTimeFormat('nl-NL', { timeZone: 'Europe/Amsterdam', hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date(value)) : '—';
const groupMetric = (name, code) => metrics[name].byGroup.find(group => group.groupCode === code);
const metricRow = (label, read) => `<tr><th scope="row">${label}</th>${Object.values(metrics).map(metric => `<td>${htmlEscape(read(metric))}</td>`).join('')}</tr>`;
const summaryRows = [metricRow('Echte unieke gewone bezoeken', metric => metric.totalOrdinaryVisits),
  metricRow('Bezoeken per groep: minimum–maximum', metric => `${metric.minOrdinaryVisits}–${metric.maxOrdinaryVisits}`),
  metricRow('Groepen zonder gewoon bezoek', metric => metric.zeroVisitGroups),
  metricRow('Gewone huizen met bezoek / beschikbaar', metric => `${metric.byPortal.filter(portal => portal.visits > 0).length} / ${metric.byPortal.length}`),
  metricRow('Werkelijke looptijd, totaal minuten', metric => minutes(metric.walkingSeconds)),
  metricRow('Ontvangstwachttijd, totaal minuten', metric => minutes(metric.receptionWaitingSeconds)),
  metricRow('Vrije tijd vóór P-38, totaal minuten', metric => minutes(metric.unallocatedBeforeFinaleSeconds)),
  metricRow('Langste afzonderlijke wachttijd, min:sec', metric => duration(metric.longestWaitSeconds)),
  metricRow('Huizen zonder bezoek', metric => metric.unvisitedPortals.join(', ') || 'Geen')].join('');
const groupRows = reviewGroups.map(group => {
  const stored = groupMetric('storedBoard', group.groupCode), old = groupMetric('oldCalculated', group.groupCode), next = groupMetric('newCalculated', group.groupCode);
  return `<tr><th scope="row"><a href="#${htmlEscape(group.groupCode)}">${htmlEscape(group.groupCode)}</a></th><td>${clock(group.startsAt)}${group.startConfirmed ? ' ✓' : ''}</td><td>${stored?.ordinaryVisits ?? 0}</td><td>${old?.ordinaryVisits ?? 0}</td><td><strong>${next.ordinaryVisits}</strong></td><td>${minutes(next.walkingSeconds)}</td><td>${minutes(next.receptionWaitingSeconds)}</td><td>${minutes(next.unallocatedBeforeFinaleSeconds)}</td><td>${clock(group.finaleChange?.previousReservedAt ?? group.finaleArrivalAt)} → ${clock(group.finaleArrivalAt)}</td><td>${clock(group.expectedCompletionAt)}</td></tr>`;
}).join('');
const portalRows = metrics.newCalculated.byPortal.map(portal => `<tr><th scope="row">${htmlEscape(portal.portalCode)}</th><td>${metrics.storedBoard.byPortal.find(item => item.portalCode === portal.portalCode)?.visits ?? 0}</td><td>${metrics.oldCalculated.byPortal.find(item => item.portalCode === portal.portalCode)?.visits ?? 0}</td><td><strong>${portal.visits}</strong></td><td>${minutes(portal.usableOpenSeconds)}</td><td>${clock(portal.firstArrivalAt)}</td><td>${minutes(portal.largestGapSeconds)}</td></tr>`).join('');
const diagnosticList = items => items.length ? `<ul>${items.map(item => `<li>${item.portalCode ? `<strong>${htmlEscape(item.portalCode)}.</strong> ` : ''}${htmlEscape(item.message)}</li>`).join('')}</ul>` : '<p>Geen.</p>';
const groupDetails = reviewGroups.map(group => `<details id="${htmlEscape(group.groupCode)}"><summary>${htmlEscape(group.groupCode)} · ${groupMetric('newCalculated', group.groupCode).ordinaryVisits} huisbezoeken · P-38 ${clock(group.finaleArrivalAt)}</summary><div class="detail-body"><p>Start ${clock(group.startsAt)} (${group.startConfirmed ? 'bevestigd' : 'opgeslagen conceptafspraak'}); gekoppeld eerste huis: ${htmlEscape(group.linkedFirstPortalCode ?? 'geen fysiek bezoek gekoppeld')}. Gewone stopgrens ${clock(group.ordinaryStopAt)}. Gewenst einde ${clock(group.desiredEndAt)}; uiterste aankomst bij P-38 ${clock(group.latestFinaleArrivalAt)}.</p><p><strong>Finaletijd expliciet te beoordelen:</strong> ${clock(group.finaleChange?.previousReservedAt ?? group.finaleArrivalAt)} → ${clock(group.finaleArrivalAt)} bij dezelfde fysieke P-38; afronding na de show ${clock(group.expectedCompletionAt)}.</p><div class="table-scroll"><table><thead><tr><th>Volgorde</th><th>Huis</th><th>Aankomst</th><th>Lopen min:sec</th><th>Lopen meter</th><th>Ontvangstwachten min:sec</th><th>Vrij vóór P-38 min:sec</th><th>Bezoek/show min:sec</th><th>Ontvangstbuffer min:sec</th></tr></thead><tbody>${group.visits.map(visit => `<tr><td>${visit.sequence}</td><th scope="row">${htmlEscape(visit.portalCode)}${visit.kind === 'finale' ? ' · finale' : ''}</th><td>${clock(visit.startsAt)}</td><td>${duration(visit.walkSeconds)}</td><td>${visit.walkMeters ?? '—'}</td><td>${duration(visit.receptionWaitingSeconds)}</td><td>${duration(visit.freeBeforeFinaleSeconds)}</td><td>${duration(visit.visitSeconds)}</td><td>${duration(visit.bufferSeconds)}</td></tr>`).join('')}</tbody></table></div><h3>Kwaliteitsadviezen</h3>${diagnosticList(group.diagnostics.filter(item => item.severity === 'warning' && !['OMITTED_PORTAL', 'FINALE_TIME_CHANGE'].includes(item.code)))}<h3>Niet opgenomen huizen en resterende grenzen</h3>${diagnosticList(group.diagnostics.filter(item => item.code === 'OMITTED_PORTAL'))}</div></details>`).join('');
const globalAdvice = summary.qualityAdvice.filter(item => !item.groupCode);
const html = `<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Gezamenlijk routevoorstel · Duindorp Halloween 2026</title><style>
:root{color-scheme:light;--ink:#1f2930;--muted:#56636b;--line:#d9dfdf;--paper:#fff;--accent:#b34615}*{box-sizing:border-box}body{margin:0;background:#f4f5f2;color:var(--ink);font:16px/1.55 system-ui,-apple-system,sans-serif}header{background:#182d30;color:#fff;padding:38px max(22px,calc((100vw - 1240px)/2))}header p{max-width:1000px;color:#e0ebea}h1{font-size:clamp(26px,4vw,39px);line-height:1.2;margin:8px 0 18px}h2{font-size:24px;margin:0 0 15px}h3{font-size:18px;margin:24px 0 10px}.eyebrow{font-weight:700;letter-spacing:.05em;color:#f7b183}main{max-width:1280px;margin:25px auto;padding:0 20px 40px}section,.source{background:var(--paper);border:1px solid var(--line);border-radius:12px;padding:24px;margin:20px 0}.status{background:#fff3dd;border-left:5px solid #cf7523;padding:15px 20px;margin:20px 0}.fine{color:var(--muted);font-size:14px}a{color:var(--accent);text-underline-offset:3px}nav{display:flex;gap:20px;flex-wrap:wrap;margin:20px 0}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:11px 10px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top;font-variant-numeric:tabular-nums}thead{background:#eef3f2}tbody th{font-weight:600}td{white-space:nowrap}tbody tr:hover{background:#faf9f4}.table-scroll{overflow:auto}code{overflow-wrap:anywhere;font-size:13px}details{margin:12px 0;background:#fff;border:1px solid var(--line);border-radius:8px;scroll-margin-top:20px}summary{cursor:pointer;padding:17px;font-weight:700}.detail-body{padding:0 20px 20px}li{margin:9px 0}.downloads{display:flex;gap:20px;flex-wrap:wrap}@media print{body{background:#fff}header{background:#fff;color:#111;padding:15px 20px}header p{color:#111}details{break-inside:avoid}section{break-inside:avoid}.table-scroll{overflow:visible}nav{display:none}}
</style></head><body><header><div class="eyebrow">31 oktober 2026 · De Duindorpse Poorten van Halloween</div><h1>Gezamenlijk routevoorstel ter beoordeling</h1><p>Maximaal haalbare echte huisbezoeken, met P-38 als enige finale. Het aparte totale loopbudget blijft zichtbaar: ${minutes(input.maxTotalWalkingSeconds)} minuten per groep. De gewone etappelimiet is ${minutes(input.maxLegWalkingSeconds)} minuten; de finale-etappe heeft geen vaste tijd- of afstandslimiet.</p></header><main><div class="status"><strong>Niet toegepast.</strong> ${htmlEscape(explanation)}</div><nav><a href="#vergelijking">Vergelijking</a><a href="#groepen">Groepen en tijdslots</a><a href="#spreiding">Huizenspreiding</a><a href="#routes">Routes en beperkingen</a><a href="#bron">Bronnen en bestanden</a></nav><section id="vergelijking"><h2>Drie verschillende planningsstanden</h2><p>Het opgeslagen bord bevat ${metrics.storedBoard.totalOrdinaryVisits} gewone bezoeken. Het oude, tijdens de controle berekende voorstel bevat ${metrics.oldCalculated.totalOrdinaryVisits} bezoeken en is nooit opgeslagen. Het nieuwe lokale voorstel bevat ${metrics.newCalculated.totalOrdinaryVisits} bezoeken. Alle drie zijn met dezelfde actuele meetfunctie vergeleken.</p><div class="table-scroll"><table><thead><tr><th>Vergelijking</th><th>Opgeslagen bord</th><th>Oud berekend voorstel</th><th>Nieuw lokaal voorstel</th></tr></thead><tbody>${summaryRows}</tbody></table></div><p class="fine">Tijden in Europe/Amsterdam (31 oktober: UTC+1). Minuten zijn afgerond op één decimaal; routetijden staan op seconden. De langste afzonderlijke wachttijd omvat ook een afzonderlijk gat vóór P-38. Het opgeslagen bord en oude voorstel zijn historische vergelijkingsstanden en zijn niet opnieuw goedgekeurd.</p></section><section><h2>Harde conflicten en kwaliteit</h2><p>Nieuwe lokale validatie: <strong>${proposal.valid && !validation.length ? 'geen harde conflicten gevonden' : 'beoordeling geblokkeerd'}</strong>. Er zijn ${reviewGroups.filter(group => group.finaleChange).length} voorgestelde tijdslotwijzigingen bij dezelfde fysieke finale P-38. Startplaatsen en starttijden zijn behouden; er zijn geen extra rondjes, verlengde bezoeken of fictieve stops toegevoegd.</p><h3>Harde conflicten</h3>${diagnosticList(summary.hardConflicts)}<h3>Algemene kwaliteitsadviezen</h3>${diagnosticList(globalAdvice)}<p class="fine">Zoekwerk: ${proposal.work.variants} varianten, ${proposal.work.pairReplans} gezamenlijke paarherplanningen en ${proposal.work.candidateEvaluations} kandidaatbeoordelingen; lokale rekentijd ${calculationMilliseconds} ms. Een beter wereldwijd alternatief is niet uitgesloten.</p></section><section id="groepen"><h2>Groepen en voorgestelde tijdslots bij P-38</h2><div class="table-scroll"><table><thead><tr><th>Groep</th><th>Start</th><th>Bord bezoeken</th><th>Oud bezoeken</th><th>Nieuw bezoeken</th><th>Lopen min</th><th>Ontvangstwachten min</th><th>Vrij vóór P-38 min</th><th>P-38 gereserveerd → voorstel</th><th>Afronding</th></tr></thead><tbody>${groupRows}</tbody></table></div><p class="fine">✓ betekent dat de startafspraak al bevestigd is. Ook opgeslagen conceptstarts zijn in dit voorstel behouden. Bezoekaantallen tellen alleen echte unieke gewone huizen; de finale staat daar los van.</p></section><section id="spreiding"><h2>Spreiding over de gewone huizen</h2><div class="table-scroll"><table><thead><tr><th>Huis</th><th>Opgeslagen bord</th><th>Oud berekend</th><th>Nieuw berekend</th><th>Bruikbare opening min</th><th>Eerste nieuwe ontvangst</th><th>Grootste open gat min</th></tr></thead><tbody>${portalRows}</tbody></table></div><p class="fine">Bruikbare opening is een conservatieve meting van rechtstreeks bereikbare ontvangstmomenten binnen start, toegankelijkheid, gewone stopgrens, apart totaal loopbudget en effectief finalevenster. Een route via andere huizen kan daarnaast passen. De meting bewijst geen onmogelijkheid en garandeert geen plaats in de gedeelde kalender.</p></section><section id="routes"><h2>Werkelijke routevolgorde en resterende beperkingen</h2><p>Open een groep voor iedere echte etappe, afzonderlijke wachttijd, voorgestelde finalewijziging en concrete uitleg bij ontbrekende huizen.</p>${groupDetails}</section><section id="bron"><h2>Bronnen en bestanden</h2><p>Invoersnapshot: ${htmlEscape(source.snapshotReadAt ?? source.localInputModifiedAt)}. De productie-invoer is uitsluitend gelezen; het nieuwe voorstel is lokaal berekend.</p><p>Bronhash <code>${htmlEscape(source.sourceHash)}</code><br>Bordhash <code>${htmlEscape(source.boardHash)}</code><br>Productieboom bij onderzoek <code>${source.productionTreeAtInvestigation}</code><br>Oude plannerblob <code>${source.oldPlannerBlob}</code><br>Nieuwe plannerbron SHA-256 <code>${source.plannerSourceSha256}</code><br>Oorspronkelijke voorstelhash <code>${proposal.proposalHash}</code></p><p class="fine">Namen, adressen, coördinaten en deelnemersgegevens zijn niet opgenomen. Interne groep- en poortidentificaties zijn vervangen door codes. De JSON is alleen een beoordelingsbestand; goedkeuring en toepassing blijven via de bestaande bevoegde wijzigingsflow verlopen. De bronhash moet bij daadwerkelijke beoordeling opnieuw actueel worden gecontroleerd.</p><div class="downloads"><a href="proposal.json">Beoordelingsvoorstel JSON</a><a href="comparison.csv">Groepsvergelijking CSV</a><a href="summary.json">Vergelijking en diagnostiek JSON</a></div></section></main></body></html>`;

const csvCell = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
const columns = ['group', 'start_local', 'start_confirmed', 'stored_ordinary_visits', 'old_calculated_ordinary_visits', 'new_ordinary_visits',
  'old_walking_seconds', 'new_walking_seconds', 'old_reception_waiting_seconds', 'new_reception_waiting_seconds',
  'old_free_before_finale_seconds', 'new_free_before_finale_seconds', 'p38_reserved_local', 'p38_proposed_local', 'completion_proposed_local', 'final_leg_walking_seconds'];
const rows = reviewGroups.map(group => {
  const old = groupMetric('oldCalculated', group.groupCode), next = groupMetric('newCalculated', group.groupCode);
  return [group.groupCode, clock(group.startsAt), group.startConfirmed, groupMetric('storedBoard', group.groupCode)?.ordinaryVisits ?? 0,
    old?.ordinaryVisits ?? 0, next.ordinaryVisits, old?.walkingSeconds ?? 0, next.walkingSeconds, old?.receptionWaitingSeconds ?? 0,
    next.receptionWaitingSeconds, old?.unallocatedBeforeFinaleSeconds ?? 0, next.unallocatedBeforeFinaleSeconds,
    clock(group.finaleChange?.previousReservedAt ?? group.finaleArrivalAt), clock(group.finaleArrivalAt), clock(group.expectedCompletionAt), group.visits.at(-1)?.walkSeconds ?? null];
});
const files = { 'review.html': html, 'proposal.json': `${JSON.stringify(reviewProposal, null, 2)}\n`,
  'comparison.csv': `\uFEFF${[columns, ...rows].map(row => row.map(csvCell).join(',')).join('\r\n')}\r\n`,
  'summary.json': `${JSON.stringify(summary, null, 2)}\n` };
for (const [name, text] of Object.entries(files)) {
  if (knownPrivateNames.some(([privateName]) => text.includes(privateName)) || /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i.test(text)) throw new Error(`PRIVATE_IDENTIFIER_IN_REPORT: ${name}`);
}
await mkdir(options.output, { recursive: true });
await Promise.all(Object.entries(files).map(([name, text]) => writeFile(join(options.output, name), text, 'utf8')));
console.log(JSON.stringify({ status: 'local-review-only', output: options.output, valid: proposal.valid, originalProposalHash: proposal.proposalHash,
  ordinaryVisits: { storedBoard: metrics.storedBoard.totalOrdinaryVisits, oldCalculated: metrics.oldCalculated.totalOrdinaryVisits, newCalculated: metrics.newCalculated.totalOrdinaryVisits },
  receptionWaitingSeconds: metrics.newCalculated.receptionWaitingSeconds, freeBeforeFinaleSeconds: metrics.newCalculated.unallocatedBeforeFinaleSeconds,
  walkingSeconds: metrics.newCalculated.walkingSeconds, calculationMilliseconds, files: Object.keys(files) }, null, 2));
