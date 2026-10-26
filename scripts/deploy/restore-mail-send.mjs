import { pathToFileURL } from "node:url";

export function restoredMailScopes(scopes) {
  if (!Array.isArray(scopes) || !scopes.length || scopes.some(scope => typeof scope !== "string")) throw new Error("INVALID_EXISTING_SCOPES");
  return scopes.includes("mail.send") ? [...scopes] : [...scopes, "mail.send"];
}

async function main() {
  if (!process.argv.includes("--apply")) throw new Error("EXPLICIT_REPAIR_REQUIRED");
  const secret = process.env.SENDGRID_API;
  const keyId = secret?.split(".")[1];
  if (!secret?.startsWith("SG.") || !/^[A-Za-z0-9_-]{16,64}$/.test(keyId ?? "")) throw new Error("INVALID_KEY_REFERENCE");
  const request = async (path, body) => {
    const response = await fetch(`https://api.sendgrid.com/v3/${path}`, {
      method: body ? "PUT" : "GET",
      headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`MAIL_PERMISSION_REPAIR_HTTP_${response.status}`);
    return response.json();
  };
  const key = await request(`api_keys/${keyId}`);
  if (key.api_key_id !== keyId || typeof key.name !== "string") throw new Error("KEY_IDENTITY_NOT_CONFIRMED");
  const scopes = restoredMailScopes(key.scopes);
  if (!key.scopes.includes("mail.send")) await request(`api_keys/${keyId}`, { name: key.name, scopes });
  const verified = await request(`api_keys/${keyId}`);
  if (verified.name !== key.name || JSON.stringify([...verified.scopes].sort()) !== JSON.stringify([...scopes].sort())) throw new Error("RESTORED_SCOPES_NOT_CONFIRMED");
  console.log(JSON.stringify({ mailSendAllowed: true, otherPermissionsPreserved: true, keyReplaced: false }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
