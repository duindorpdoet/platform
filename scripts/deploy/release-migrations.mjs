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
  '20261024145517_start_location_readiness.sql',
  '20261025023205_portal_sequence_without_street_routing.sql',
  '20261025090000_group_operations_foundation.sql',
  '20261025090100_group_operations_commands.sql',
  '20261025090200_group_operations_projections.sql',
  '20261025090300_semantic_start_communication.sql',
  '20261025090400_canonical_visits_and_occupancy.sql',
  '20261025090500_portal_drafts_and_confirmed_receptions.sql',
]);

export function assertReviewedReleaseMigrations(files) {
  if(!Array.isArray(files)||JSON.stringify(files)!==JSON.stringify(REVIEWED_RELEASE_MIGRATIONS))throw new Error('REVIEWED_MIGRATION_SET_CHANGED');
}
export function reviewedRepositoryMigrations(repositoryFiles) {
  const pendingScope=repositoryFiles.filter(name=>name>=REVIEWED_RELEASE_MIGRATIONS[0]).sort();
  assertReviewedReleaseMigrations(pendingScope);
  return pendingScope;
}
