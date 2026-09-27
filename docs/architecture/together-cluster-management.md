# Samenloop cluster identity and organizer linking

`20260926224708_together_cluster_management.sql` adds nullable `together_parties.cluster_reference`. A cluster reference has the form `SL-2026-K7M4PQ`: the event's year and six cryptographically random symbols from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`. The `(event_id, cluster_reference)` unique constraint also supplies the lookup index. Generation locks the party, retries collisions up to 32 times and never replaces an existing reference. Once assigned, a reference cannot be changed, cleared or deleted, including after the source party becomes historical.

The backfill only assigns references to existing parties with at least two active memberships pointing to submitted registrations in the same event. It creates no parties and changes no memberships, individual references, four-character codes or walking assignments. The same private helper runs after accepted joins, manual merges and membership changes. A singleton has no new reference; an existing historical reference remains intact.

Individual `registration.reference`, individual four-character `registration.together_code`, party UUIDs and authoritative `together_memberships` remain unchanged. Participants still submit a four-character code, creating a pending request. The existing accepted/rejected decision and capacity-override contracts remain in place. `admin_group_move_registration` is unchanged: the frontend sends one deterministically selected registration UUID, and the server moves its complete party.

## Organizer APIs

All new API functions revoke PUBLIC/anon execution, grant authenticated execution, then require `event_admin`, `registration_manage` or `groups_manage` for the requested event. A cluster reference grants no authorization.

- `admin_together_management_snapshot(event_slug, query, limit, offset)` returns confirmed parties, pending requests, informational problems, totals and the private realtime topic. Pages are capped at 100 entries per category (UI uses 50). One set-based party projection supplies all three categories; matching an individual member keeps the entire party in the result.
- `admin_together_resolve_identifier(event_slug, identifier)` is read-only and accepts an exact registration reference, four-character code or cluster reference after trimming/uppercasing. Empty historical parties cannot be mutation targets.
- `admin_together_merge_preview(event_slug, source_party_id, target_party_id)` returns both parties, counts, blockers and opaque state digests. Digests cover members, preferences, current groups, locks, publication, event phase and current capacity settings.
- `admin_merge_together_parties(event_slug, source_party_id, target_party_id, expected_source_state, expected_target_state, reason, idempotency_key)` rechecks the preview under event, registration, party and walking-group locks. Identifiers are never re-resolved in the mutation. The reason must have 10–500 characters. Retries with the same actor/key/arguments return the original receipt; mismatching reuse fails.

Manual linking permits two unassigned parties or parties wholly assigned to the same draft walking group. It blocks different or partial assignments, published/locked groups, locked parties, inactive memberships, the same party, stale previews and over-capacity results. Manual linking does not offer an override; the existing join-request decision retains its explicit override flow. An outgoing pending request must first be decided or withdrawn through the existing workflow. Incoming requests aimed at the source are retargeted to the surviving party.

A merge moves active memberships atomically, locks the emptied source and preserves the target reference (or creates one when two singletons join). It never changes walking assignments. Audit action `together.admin_merged` records party IDs/references, resulting registration IDs, child count and reason, without household details. One receipt and audit event are written for an idempotent command.

`admin_group_composition_snapshot` and `admin_registrations_snapshot` additionally expose `clusterReference`; the roster also exposes `partyId`. Existing permissions and fields are retained. `admin_decide_together_request` explicitly ensures the accepted target's identity and now takes the event lock before the request lock, matching other event mutations. Its retry and override semantics remain unchanged.

## Interface and refresh

The central organizer navigation exposes **Samenloop** on desktop and in mobile **Meer**. Its confirmed, open-request and problem views share universal search. Manual linking uses an accessible native modal: resolve, preview, reason, confirm. Hard blockers omit the mutation button. Group composition displays/searches the SL reference, retains expanded member details and uses the original representative internally. Missing references show “Samenloop · reference ontbreekt”; clients never invent codes.

Membership and request changes send identifier-only `snapshot_changed` broadcasts on the existing private `admin-event:<event_id>` topic. Together management, registrations and group composition refetch; registration managers are authorized for the same topic. Polling remains a fallback. Accepted-request mail may contain the safe cluster number, using the existing authorized recipients and no new household details.

## Participant follow-up requested during implementation

`20260926231835_participant_together_requests.sql` adds an ownership-scoped `registration_together_snapshot(registration_id)` and `registration_together_request(registration_id, together_code, idempotency_key)`. The latter accepts only a four-character code and creates a pending `together_join_request`; it does not merge memberships or expose the target's household data. Existing outgoing requests, finalized groups, incompatible walking assignments and the hard twenty-child ceiling block new requests. Requests above the configured event limit still require the existing organizer override decision.

A shared component on **Mijn inschrijving** and **Groep** (including before walking-group assignment) shows requested, approved, rejected and withdrawn statuses. Confirmed members see only their own cluster number and member count. Open outgoing requests can be cancelled through the existing idempotent `together_join_request_withdraw` endpoint; cancellation leaves the registration intact. An approval racing a withdrawal fails the stale withdrawal safely. Private `registration:<id>` broadcasts authorize only that registration's own household and refresh status after requests, decisions or membership changes. Neither the new snapshot nor the request endpoint acts as a household directory.

## Deliberate follow-ups

Unlinking is not implemented. The former `api.together_leave` was explicitly retired by the four-character-code migration; there is no current safe organizer contract for splitting membership history and assignments. A separate reviewed contract must cover publication/locks, singleton restoration, audit and idempotency. Confirmed-cluster unlinking remains a follow-up; participants can withdraw their own pending request using the existing contract. SL numbers are not participant lookup tokens. No automatic problem repair is offered.

## Validation

Run against an isolated local Supabase only:

- `pnpm verify`
- Complete migration reset and `supabase test db`
- `scripts/acceptance/concurrency.mjs` and `scripts/acceptance/together-concurrency.mjs`
- `playwright test tests/e2e/authenticated-live.spec.ts tests/e2e/together-management.spec.ts`

The together fixture helper refuses non-local URLs and targets only the configured local Docker database. The new contracts cover collision retry/exhaustion, immutable history, backfill invariants, approval retries, manual merge scenarios, capacity/group/publication conflicts, event boundaries, permissions, whole-party moves and audit idempotency. Parallel acceptance races generators, repeated confirmations and competing destinations. Browser acceptance uses real local RPCs for search, preview, cancel, confirmation, blockers, stale data, realtime and bundle moves.
