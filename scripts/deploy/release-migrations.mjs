// Explicit reviewed release set. Additions require backup/restore review.
export const REVIEWED_RELEASE_MIGRATIONS=Object.freeze([
  '20261023014941_inclusive_arrivals_and_household_departure.sql',
  '20261023014942_guidance_reading_thanks_and_print_material.sql',
  '20261023020159_isolated_server_rehearsal.sql',
  '20261023021247_reviewed_arrival_backfill_contract.sql',
  '20261023151900_essential_event_notices.sql',
  '20261023153000_event_group_size_policy.sql',
  '20261023153100_group_size_contracts.sql',
  '20261023153101_group_request_and_route_policy.sql',
  '20261023160000_immutable_start_publications.sql',
  '20261023160100_startregie_confirmation_and_reservations.sql',
  '20261023160200_startregie_server_contracts.sql',
  '20261023160300_startregie_expected_routes.sql',
  '20261023160400_startregie_snapshot_and_location_revisions.sql',
  '20261023160500_startregie_dispatch_and_child_projection.sql',
  '20261023160600_startregie_plan_preconditions.sql',
  '20261023160700_amsterdam_and_capacity_guards.sql',
  '20261023160800_start_projection_in_queued_mail.sql',
  '20261023160900_amsterdam_command_boundaries.sql',
  '20261023161000_push_admission_security.sql',
  '20261023161100_push_delivery_revalidation.sql',
  '20261023161200_bounded_push_claims.sql',
  '20261023161300_reviewed_portal_walking_connections.sql',
  '20261023222934_portal_management_hotfix.sql',
  '20261023224435_portal_start_point_choice.sql',
  '20261023234741_simple_start_confirmation.sql',
  '20261024024428_evening_readiness_evidence.sql',
  '20261024025222_evening_visit_information.sql',
  '20261024034343_evening_route_transaction_order.sql',
  '20261024042005_evening_ordinary_capacity.sql',
  '20261024043647_evening_finale_commitments.sql',
  '20261024050939_evening_live_route_context.sql',
  '20261024054230_evening_route_candidates.sql',
  '20261024064423_evening_route_reviews.sql',
  '20261024065647_evening_physical_admission.sql',
  '20261024071646_evening_legacy_route_binding.sql',
  '20261024100115_evening_closed_current_instruction.sql',
  '20261024112932_evening_nonblocking_channel_reads.sql',
]);

export function assertReviewedReleaseMigrations(files) {
  if(!Array.isArray(files)||JSON.stringify(files)!==JSON.stringify(REVIEWED_RELEASE_MIGRATIONS))throw new Error('REVIEWED_MIGRATION_SET_CHANGED');
}
export function reviewedRepositoryMigrations(repositoryFiles) {
  const pendingScope=repositoryFiles.filter(name=>name>=REVIEWED_RELEASE_MIGRATIONS[0]).sort();
  assertReviewedReleaseMigrations(pendingScope);
  return pendingScope;
}
