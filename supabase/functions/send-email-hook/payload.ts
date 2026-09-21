export type HookPayload = {
  user: { email?: string; new_email?: string };
  email_data: { token?: string; token_new?: string; token_hash?: string; token_hash_new?: string; email_action_type?: string };
};

export type HookDelivery = { email: string; token: string };

const SUPPORTED_ACTIONS = new Set([
  "signup",
  "invite",
  "magiclink",
  "email",
  "recovery",
  "email_change",
  "reauthentication",
  "staging_provider_probe",
]);

export function deliveriesForPayload(payload: HookPayload): { deliveries: HookDelivery[]; supported: boolean } {
  const action = payload.email_data.email_action_type;
  if (!action || !SUPPORTED_ACTIONS.has(action)) return { deliveries: [], supported: false };

  const deliveries: HookDelivery[] = [];
  if (action === "email_change" && payload.user.new_email) {
    if (payload.email_data.token && payload.email_data.token_hash_new && payload.user.email) {
      deliveries.push({ email: payload.user.email, token: payload.email_data.token });
    }
    if (payload.email_data.token_new && payload.email_data.token_hash) {
      deliveries.push({ email: payload.user.new_email, token: payload.email_data.token_new });
    }
    if (deliveries.length === 0) {
      const fallbackToken = payload.email_data.token_new ?? payload.email_data.token;
      if (fallbackToken) deliveries.push({ email: payload.user.new_email, token: fallbackToken });
    }
  } else if (payload.user.email && payload.email_data.token) {
    deliveries.push({ email: payload.user.email, token: payload.email_data.token });
  }
  return { deliveries, supported: true };
}
