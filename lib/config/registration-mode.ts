export type RegistrationMode = "closed" | "staging_test" | "live";

export function registrationChannelIsOpen(mode: RegistrationMode, configuredOpen?: boolean | null) {
  if (mode === "closed") return false;
  return configuredOpen ?? true;
}
