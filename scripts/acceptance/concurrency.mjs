import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_ANON_KEY;
if (!url || !key) throw new Error("Local Supabase URL and public key are required");

const eventSlug = "duindorp-halloween-2026";
const groupId = "23000000-0000-0000-0000-000000000001";

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function actor(email) {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await client.auth.signInWithPassword({ email, password: "local-test-only" });
  if (error) throw new Error(`Fixture login failed for ${email}: ${error.code ?? error.message}`);
  return client;
}

async function api(client, name, args) {
  return client.schema("api").rpc(name, args);
}

function exactlyOneSuccess(results, label) {
  const success = results.filter((result) => !result.error);
  const failed = results.filter((result) => result.error);
  check(success.length === 1 && failed.length === 1, `${label}: expected one commit and one conflict`);
  return success[0].data;
}

const parent = await actor("parent-b@example.invalid");
const registrationPayload = {
  adult: { name: "Concurrency ouder", householdLabel: "Concurrency testgezin", phone: "0612345678" },
  children: [{ name: "Concurrency kind", age: "9", accessibilityNote: "" }],
  marketingConsent: false,
};
let result = await api(parent, "registration_save_draft", { _event_slug: eventSlug, _payload: registrationPayload, _expected_version: null });
check(!result.error, `registration draft failed: ${result.error?.message}`);
const registrationResults = await Promise.all([
  api(parent, "registration_submit", { _event_slug: eventSlug, _terms_version: "test-v1", _privacy_version: "test-v1", _idempotency_key: "parallel-registration-a", _request_hash: "parallel-registration" }),
  api(parent, "registration_submit", { _event_slug: eventSlug, _terms_version: "test-v1", _privacy_version: "test-v1", _idempotency_key: "parallel-registration-b", _request_hash: "parallel-registration" }),
]);
check(registrationResults.every((item) => !item.error), "parallel registration calls should converge on the existing household registration");
check(registrationResults[0].data.id === registrationResults[1].data.id, "parallel registration created different logical registrations");
result = await api(parent, "registration_snapshot", { _event_slug: eventSlug });
check(!result.error && result.data.registration.id === registrationResults[0].data.id, "registration snapshot does not match the converged submit result");

const applicant = await actor("leader-b@example.invalid");
const portalPayload = {
  contactName: "Concurrency bewoner",
  phone: "0612345678",
  address: { street: "NIET-BESTAAND PARALLELPAD", houseNumber: "2", addition: "", postalCode: "2584 AB" },
  entrance: "Zelfde ingang als het opgegeven testadres",
  requestedWorldSlug: "heksenrijk",
  portalName: "De Parallelpoort",
  description: "Een fictieve aanvraag voor de dubbele goedkeuringstest.",
  intensity: "2",
  warnings: { smoke: false, flashes: false, sound: false, actors: false, allergens: false },
  warningNotes: "",
  availableFrom: "18:00",
  availableUntil: "22:00",
  visitMinutes: "5",
  maxConcurrentGroups: "1",
  maxChildrenPerVisit: "12",
  maxChildrenTotal: "120",
  accessibility: "unknown",
  accessibilityNotes: "",
  availability: true,
  locationConsent: true,
};
result = await api(applicant, "portal_application_save", { _event_slug: eventSlug, _payload: portalPayload, _expected_version: null });
check(!result.error, `portal draft failed: ${result.error?.message}`);
const applicationId = result.data.id;
result = await api(applicant, "portal_application_submit", { _application_id: applicationId, _expected_version: result.data.version, _idempotency_key: "parallel-portal-submit", _request_hash: "parallel-portal-submit" });
check(!result.error, `portal submit failed: ${result.error?.message}`);

const adminA = await actor("admin@example.invalid");
const adminB = await actor("admin@example.invalid");
const reviewArgs = { _application_id: applicationId, _expected_version: result.data.version, _decision: "approved", _world_slug: "heksenrijk", _latitude: null, _longitude: null, _reason: "Volledige parallelle beoordeling akkoord" };
exactlyOneSuccess(await Promise.all([
  api(adminA, "admin_review_portal_application", reviewArgs),
  api(adminB, "admin_review_portal_application", reviewArgs),
]), "parallel portal approval");
result = await api(applicant, "portal_snapshot", { _event_slug: eventSlug });
check(!result.error && result.data.application.status === "approved" && result.data.portal?.id, "parallel approval did not converge on one approved portal");

const beforeDashboard = await api(adminA, "admin_dashboard", { _event_slug: eventSlug });
const planning = await api(adminA, "admin_planning_snapshot", { _event_slug: eventSlug });
check(!beforeDashboard.error && !planning.error, "admin planning input unavailable");
const registrationId = registrationResults[0].data.id;
check(planning.data.parties.some((party) => party.id === registrationId), "new registration is not available for planning");
const proposal = {
  groups: [{ key: "parallel-last-place", partyIds: [registrationId], childCount: 1, startId: planning.data.starts[0].id, portalIds: planning.data.portals.slice(0, 6).map((portal) => portal.id) }],
  conflicts: [],
};
const planResults = await Promise.all([
  api(adminA, "admin_apply_plan", { _event_slug: eventSlug, _proposal: proposal, _input_hash: "parallel-plan", _idempotency_key: "parallel-plan-a", _request_hash: "parallel-plan-a" }),
  api(adminB, "admin_apply_plan", { _event_slug: eventSlug, _proposal: proposal, _input_hash: "parallel-plan", _idempotency_key: "parallel-plan-b", _request_hash: "parallel-plan-b" }),
]);
exactlyOneSuccess(planResults, "parallel final planning place");
const afterDashboard = await api(adminA, "admin_dashboard", { _event_slug: eventSlug });
check(!afterDashboard.error && afterDashboard.data.counts.groups === beforeDashboard.data.counts.groups + 1, "parallel planning created zero or multiple groups");

const leaderA = await actor("leader-a@example.invalid");
const leaderB = await actor("leader-a@example.invalid");
const ownParent = await actor("parent-size-1@example.invalid");
const roster = await api(leaderA, "group_roster", { _group_id: groupId });
let group = await api(leaderA, "group_snapshot", { _group_id: groupId });
check(!roster.error && !group.error && roster.data.length === 1, "live concurrency fixture is unavailable");
result = await api(leaderA, "run_start", {
  _group_id: groupId,
  _present_registration_child_ids: roster.data.map((item) => item.registrationChildId),
  _expected_group_version: group.data.group.version,
  _idempotency_key: "parallel-run-start",
  _request_hash: "parallel-run-start",
});
check(!result.error, `run start failed: ${result.error?.message}`);

async function current() {
  const snapshotResult = await api(leaderA, "group_snapshot", { _group_id: groupId });
  check(!snapshotResult.error && snapshotResult.data.run?.currentStop, "expected an active current stop");
  return snapshotResult.data;
}

async function scanAndVisit(sequence) {
  const snapshot = await current();
  const run = snapshot.run;
  const stop = run.currentStop;
  check(stop.sequence === sequence, `expected stop ${sequence}, got ${stop.sequence}`);
  let command = await api(leaderA, "run_scan", { _run_id: run.id, _expected_stop_id: stop.id, _expected_run_version: run.version, _credential: `TEST-PORTAL-${String(sequence).padStart(2, "0")}-TOKEN`, _method: "qr" });
  check(!command.error, `scan at stop ${sequence} failed: ${command.error?.message}`);
  const refreshed = await current();
  const participant = refreshed.run.participants[0];
  command = await api(leaderA, "run_update_participant", { _run_id: refreshed.run.id, _stop_id: refreshed.run.currentStop.id, _run_participant_id: participant.id, _new_status: "visited", _expected_run_version: refreshed.run.version, _expected_status_version: participant.statusVersion, _reason: null });
  check(!command.error, `visit at stop ${sequence} failed: ${command.error?.message}`);
  return current();
}

let live = await scanAndVisit(1);
const sameKeyArgs = { _run_id: live.run.id, _stop_id: live.run.currentStop.id, _expected_run_version: live.run.version, _all_skip_confirmed: false, _idempotency_key: "parallel-complete-same-key", _request_hash: "parallel-complete-same-hash" };
const sameKeyResults = await Promise.all([
  api(leaderA, "run_complete_stop", sameKeyArgs),
  api(leaderB, "run_complete_stop", sameKeyArgs),
]);
check(sameKeyResults.every((item) => !item.error), "same-key concurrent completion did not return the committed receipt to both callers");
check(JSON.stringify(sameKeyResults[0].data) === JSON.stringify(sameKeyResults[1].data), "same-key concurrent completion returned inconsistent results");
live = await current();
check(live.run.currentStop.sequence === 2 && live.run.history.length === 1, "same-key completion advanced more than once");

live = await scanAndVisit(2);
const differentKeys = ["parallel-complete-different-a", "parallel-complete-different-b"];
const differentResults = await Promise.all(differentKeys.map((idempotencyKey) => api(leaderA, "run_complete_stop", {
  _run_id: live.run.id,
  _stop_id: live.run.currentStop.id,
  _expected_run_version: live.run.version,
  _all_skip_confirmed: false,
  _idempotency_key: idempotencyKey,
  _request_hash: `hash-${idempotencyKey}`,
})));
exactlyOneSuccess(differentResults, "different-key completion of one old stop");
const winningIndex = differentResults.findIndex((item) => !item.error);
const retry = await api(leaderA, "run_complete_stop", {
  _run_id: live.run.id,
  _stop_id: live.run.currentStop.id,
  _expected_run_version: live.run.version,
  _all_skip_confirmed: false,
  _idempotency_key: differentKeys[winningIndex],
  _request_hash: `hash-${differentKeys[winningIndex]}`,
});
check(!retry.error && JSON.stringify(retry.data) === JSON.stringify(differentResults[winningIndex].data), "retry after a lost response did not recover the committed receipt");
live = await current();
check(live.run.currentStop.sequence === 3 && live.run.history.length === 2, "different-key race advanced more than one stop");

result = await api(leaderA, "run_scan", { _run_id: live.run.id, _expected_stop_id: live.run.currentStop.id, _expected_run_version: live.run.version, _credential: "TEST-PORTAL-03-TOKEN", _method: "qr" });
check(!result.error, "stop 3 scan failed");
live = await current();
const contestedParticipant = live.run.participants[0];
const participantArgs = { _run_id: live.run.id, _stop_id: live.run.currentStop.id, _run_participant_id: contestedParticipant.id, _expected_run_version: live.run.version, _expected_status_version: contestedParticipant.statusVersion };
exactlyOneSuccess(await Promise.all([
  api(ownParent, "run_update_participant", { ...participantArgs, _new_status: "skipped", _reason: null }),
  api(leaderA, "run_update_participant", { ...participantArgs, _new_status: "visited", _reason: null }),
]), "parent skip versus leader visit");
live = await current();
check(["skipped", "visited"].includes(live.run.participants[0].status) && live.run.participants[0].statusVersion === 2, "participant race silently overwrote the winning decision");
result = await api(leaderA, "run_complete_stop", { _run_id: live.run.id, _stop_id: live.run.currentStop.id, _expected_run_version: live.run.version, _all_skip_confirmed: live.run.participants[0].status === "skipped", _idempotency_key: "parallel-stop-3-cleanup", _request_hash: "parallel-stop-3-cleanup" });
check(!result.error, "could not complete the resolved third stop");

live = await current();
result = await api(leaderA, "run_scan", { _run_id: live.run.id, _expected_stop_id: live.run.currentStop.id, _expected_run_version: live.run.version, _credential: "TEST-PORTAL-04-TOKEN", _method: "qr" });
check(!result.error, "stop 4 scan failed");
live = await current();
const lastPending = live.run.participants[0];
const decisionResult = await Promise.all([
  api(leaderA, "run_complete_stop", { _run_id: live.run.id, _stop_id: live.run.currentStop.id, _expected_run_version: live.run.version, _all_skip_confirmed: false, _idempotency_key: "complete-versus-decision", _request_hash: "complete-versus-decision" }),
  api(leaderA, "run_update_participant", { _run_id: live.run.id, _stop_id: live.run.currentStop.id, _run_participant_id: lastPending.id, _new_status: "visited", _expected_run_version: live.run.version, _expected_status_version: lastPending.statusVersion, _reason: null }),
]);
check(!decisionResult[1].error, "the last participant decision was lost in the completion race");
live = await current();
if (live.run.currentStop.sequence === 4) {
  check(live.run.participants[0].status === "visited", "failed completion left an unresolved participant set");
} else {
  check(live.run.currentStop.sequence === 5 && live.run.history.length === 4, "successful raced completion produced an inconsistent next stop");
}

// Two HTTP transactions must converge on one shared payment and one allocation.
const paymentSnapshot = await api(adminA, "admin_payments_snapshot", { _event_slug: eventSlug });
check(!paymentSnapshot.error, "payment snapshot unavailable");
const selectedPayments = paymentSnapshot.data.filter((payment) => payment.reference.startsWith("PAY-BROWSER-PAYMENT-")).sort((a, b) => a.reference.localeCompare(b.reference));
check(selectedPayments.length === 2, "shared payment fixtures missing");
const publishPaymentArgs = {
  _event_slug: eventSlug,
  _payments: selectedPayments.map(({ id, version }) => ({ id, version })),
  _payer_payment_request_id: selectedPayments[0].id,
  _external_url: "https://tikkie.me/pay/parallel-shared-test",
  _reason: "Parallelle gedeelde betaling controleren",
  _idempotency_key: "parallel-shared-publish",
};
const publicationResults = await Promise.all([
  api(adminA, "admin_payment_batch_publish", publishPaymentArgs),
  api(adminB, "admin_payment_batch_publish", publishPaymentArgs),
]);
check(publicationResults.every((item) => !item.error), `parallel payment publication failed: ${publicationResults.find((item) => item.error)?.error?.message}`);
check(publicationResults[0].data.id === publicationResults[1].data.id, "parallel publication created two batches");
const sharedPayment = publicationResults[0].data;
const confirmPaymentArgs = {
  _batch_id: sharedPayment.id, _expected_version: sharedPayment.version,
  _amount_cents: 750, _external_reference: "PARALLEL-SHARED-PAYMENT",
  _reason: "Totaal eenmaal ontvangen en gecontroleerd", _idempotency_key: "parallel-shared-confirm",
};
const paymentConfirmations = await Promise.all([
  api(adminA, "admin_payment_batch_confirm", confirmPaymentArgs),
  api(adminB, "admin_payment_batch_confirm", confirmPaymentArgs),
]);
check(paymentConfirmations.every((item) => !item.error), "parallel payment confirmation did not return the same receipt");
const finalPayments = await api(adminA, "admin_payments_snapshot", { _event_slug: eventSlug });
const allocations = finalPayments.data.filter((payment) => selectedPayments.some((selected) => selected.id === payment.id));
check(allocations.every((payment) => payment.status === "confirmed" && payment.netCollectedCents === payment.amountCents), "joint payment was duplicated or allocated incorrectly");
check(allocations.reduce((sum, payment) => sum + payment.netCollectedCents, 0) === 750, "shared ledger total was not booked exactly once");

console.log(JSON.stringify({
  status: "pass",
  checks: ["REG-04", "HOUSE-02", "PLAN-06", "RACE-01", "RACE-02", "RACE-04", "RACE-05", "RACE-06", "PAYMENT-SHARED-RACE"],
}));
