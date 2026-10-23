/** PostgreSQL integer storage boundary; the organizer chooses the product limit. */
export const GROUP_SIZE_STORAGE_MAX = 2_147_483_647;
export function parseGroupSize(value: string | number): number | null {
  if (typeof value === "string" && !/^[0-9]+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= GROUP_SIZE_STORAGE_MAX ? parsed : null;
}
