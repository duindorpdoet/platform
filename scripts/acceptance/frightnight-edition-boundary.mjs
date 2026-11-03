// Read-only selection proof. Canonical entry is intentionally public to a
// confirmed actor; an uninvited private sibling must leave the signed context intact.
export async function verifyEditionBoundary({ canonicalSlug, parentSlug, parentEventId, foreignSlug, foreignEventId, select, readContext }) {
  const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
  if (canonicalSlug !== 'frightnight-2027-test' || !parentSlug.startsWith(canonicalSlug + '-acceptance-')
      || foreignSlug !== parentSlug + '-foreign' || !uuid.test(parentEventId) || !uuid.test(foreignEventId)
      || parentEventId === foreignEventId) throw new Error('FOREIGN_PRIVATE_EDITION_PROOF_REQUIRED');
  const canonical = await select(canonicalSlug);
  if (canonical.status !== 200 || canonical.selected !== canonicalSlug) throw new Error('CONFIRMED_CANONICAL_ENTRY_DENIED');
  const restored = await select(parentSlug);
  if (restored.status !== 200 || restored.selected !== parentSlug) throw new Error('PARENT_EDITION_RESTORE_FAILED');
  const before = await readContext();
  if (before.eventId !== parentEventId || before.slug !== parentSlug || !before.signedCookie) throw new Error('SIGNED_PARENT_CONTEXT_REQUIRED');
  const foreign = await select(foreignSlug);
  if (foreign.status !== 403) throw new Error('FOREIGN_PRIVATE_EDITION_SELECTION_ALLOWED');
  const after = await readContext();
  if (after.eventId !== parentEventId || after.slug !== parentSlug || after.signedCookie !== before.signedCookie) throw new Error('DENIED_SELECTION_CHANGED_SIGNED_CONTEXT');
  return { canonicalEntry: true, privateSiblingDenied: true, signedParentContextUnchanged: true };
}
