// Preserve the unrelated, already installed staging expansion when testing
// the production hotfix. These files are never added to the production release
// or executed by this compatibility path.
export const HOTFIX_BRANCH = "codex/portal-sequence-without-street-routing";
export const STAGING_SOURCE_REVISION = "a0263258c03a5aaed5c08445c461aed3f3206756";
export const STAGING_INSTALLED_MIGRATIONS = Object.freeze({
  '20261024024428_evening_readiness_evidence.sql': '9c0d1a99f0be1ed817177a50a3e29dfe858daf46549a18c3912f6df1db811544',
  '20261024025222_evening_visit_information.sql': '07dc957d608b91f3e69db0b0b44349d33630a2ec07078e4b5e27b6b3fac86328',
  '20261024034343_evening_route_transaction_order.sql': '4001b47c6f886c1f97841b1393abc7138165bf0330504407c6feff1ead028fba',
  '20261024042005_evening_ordinary_capacity.sql': '5b1012b9912489857b3e3703e4a89518e5f894f8fde2e06d968420a224aabccc',
  '20261024043647_evening_finale_commitments.sql': '493dbc55ad6abf2d75551c8ded3e0b22ec0754f3d400e04995a3d699c71e8770',
  '20261024050939_evening_live_route_context.sql': 'ee1212db54456934772386db84f037e8c16f74ecc19cea97954cef9b32405019',
  '20261024054230_evening_route_candidates.sql': '6f1921c592e10ecdf9fe99ead4f6550db9acd63ab7943fd41b9ac130935261b4',
  '20261024064423_evening_route_reviews.sql': '6d8f62359e19a335d38523a2b399f76dfb66b852864eabf71480b2656ba0dead',
  '20261024065647_evening_physical_admission.sql': '1be301faab6d4136982281e499c14d4e4439d51f5a76163c2ffeb138a956a143',
  '20261024071646_evening_legacy_route_binding.sql': '689477306a0a4709c4a1b6973235b7d88112d47834439c340bd15ac408334ea3',
  '20261024100115_evening_closed_current_instruction.sql': '2293da6aedf5692b1ad3033d81bcea68123b26f4744b268f37456120a2298271',
  '20261024112932_evening_nonblocking_channel_reads.sql': '351cb5212d8ac5b7efaa44377495041a22a145fef37e624606ef9e5b5b4fee54',
  '20261024125139_evening_cockpit_aggregation.sql': '412c90c2a6ed3ccf056e7b16290a465a98e53866aa75e0e450189d3d9ca74d8b',
});

export function installedStagingHistory(context = process.env) {
  return context.APP_ENVIRONMENT === "staging" && context.GITHUB_REF === `refs/heads/${HOTFIX_BRANCH}`
    ? Object.keys(STAGING_INSTALLED_MIGRATIONS) : [];
}

export function missingInstalledFiles(repositoryFiles, appliedVersions, context = process.env) {
  const local = new Set(repositoryFiles.map(name => name.split("_")[0]));
  const allowed = new Map(installedStagingHistory(context).map(file => [file.split("_")[0], file]));
  return appliedVersions.filter(version => !local.has(version)).map(version => {
    const file = allowed.get(version);
    if (!file) throw new Error("LIVE_MIGRATION_HISTORY_DRIFT");
    return file;
  });
}
