import { compositionItems, itemChildren, type CompositionRegistration } from "./group-composition";
import { dominantStartPreference } from "./start-preference";

export type AutofillGroup = { key: string; registrationIds: string[]; childCount: number; preferredStartAt: string | null; warnings: string[] };
/** Stable intact blocks; nearest preference first, then the closest fill around the soft target. */
export function proposeGroupAutofill(registrations: CompositionRegistration[], maximum: number, target = 15): AutofillGroup[] {
  const effectiveTarget = Math.min(target, maximum);
  if (!Number.isSafeInteger(effectiveTarget) || effectiveTarget < 1) throw new Error("INVALID_GROUP_LIMIT");
  const remaining = compositionItems(registrations).filter(item => itemChildren(item) > 0).map(item => ({ ...item, size: itemChildren(item), preference: dominantStartPreference(item.registrations) }))
    .sort((a, b) => (a.preference ?? "~").localeCompare(b.preference ?? "~") || b.size - a.size || a.id.localeCompare(b.id));
  const result: AutofillGroup[] = [];
  while (remaining.length) {
    const seed = remaining.shift()!;
    const members = [...seed.registrations];
    let size = seed.size;
    while (size < effectiveTarget) {
      const preference = dominantStartPreference(members);
      const candidates = remaining.map((block, index) => ({ block, index,
        distance: preference && block.preference ? Math.abs(Date.parse(preference) - Date.parse(block.preference)) : 0,
        fill: Math.abs(effectiveTarget - size - block.size) }))
        .filter(c => size + c.block.size <= maximum && Math.abs(effectiveTarget - size - c.block.size) <= effectiveTarget - size)
        .sort((a, b) => a.distance - b.distance || a.fill - b.fill || a.block.id.localeCompare(b.block.id));
      if (!candidates.length) break;
      const next = remaining.splice(candidates[0].index, 1)[0];
      members.push(...next.registrations); size += next.size;
    }
    result.push({ key: `group-${String(result.length + 1).padStart(3, "0")}`, registrationIds: members.map(r => r.id).sort(), childCount: size,
      preferredStartAt: dominantStartPreference(members), warnings: size > maximum ? ["EVENT_MAXIMUM_EXCEPTION_REQUIRED"] : size > effectiveTarget ? ["INTACT_BLOCK_ABOVE_TARGET"] : [] });
  }
  return result;
}
