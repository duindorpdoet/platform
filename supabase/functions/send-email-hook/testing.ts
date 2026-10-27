// These provider-owned sinks are allowed exclusively by an explicit, signed,
// durable mail_provider_test command. They never broaden normal staging policy.
export const resendTestRecipients = ["delivered@resend.dev", "bounced@resend.dev", "complained@resend.dev", "suppressed@resend.dev"] as const;
export function simulatedTestRecipient(email: string) {
  return (resendTestRecipients as readonly string[]).includes(email.trim().toLowerCase());
}
