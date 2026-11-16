type Call = { name: string; payload: Record<string, unknown> };
declare global { interface Window { updateCalls: Call[] } }
export function createClient() {
  return { schema: () => ({ rpc: async (name: string, payload: Record<string, unknown>) => {
    window.updateCalls ??= [];
    window.updateCalls.push({ name, payload });
    return { data: { emailCount: payload._send_email ? 2 : 0 }, error: null };
  } }) };
}
