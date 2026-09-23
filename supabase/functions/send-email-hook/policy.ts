// Authentication mail is user-requested; transactional staging mail stays restricted.
export function recipientAllowed(mode: string, email: string, allowlist: Set<string>) {
  return mode === "live" || mode === "sandbox" || (mode === "allowlist" && allowlist.has(email.trim().toLowerCase()));
}
