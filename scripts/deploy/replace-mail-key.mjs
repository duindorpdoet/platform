import { constants, createPublicKey, publicEncrypt } from "node:crypto";
import { restoredMailScopes } from "./restore-mail-send.mjs";

async function main() {
  const publicKey = createPublicKey(Buffer.from(process.env.MAIL_REPAIR_PUBLIC_KEY ?? "", "base64").toString());
  if (publicKey.asymmetricKeyType !== "rsa" || publicKey.asymmetricKeyDetails.modulusLength < 3072) throw new Error("REPAIR_TRANSPORT_KEY_REQUIRED");
  const original = process.env.SENDGRID_API;
  const originalId = original?.split(".")[1];
  if (!original?.startsWith("SG.") || !/^[A-Za-z0-9_-]{16,64}$/.test(originalId ?? "")) throw new Error("INVALID_KEY_REFERENCE");
  const request = (path, method = "GET", body, secret = original) => fetch(`https://api.sendgrid.com/v3/${path}`, {
    method, headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(10_000),
  });
  const existing = await request(`api_keys/${originalId}`);
  if (!existing.ok) throw new Error(`KEY_INSPECTION_HTTP_${existing.status}`);
  const metadata = await existing.json();
  if (metadata.api_key_id !== originalId) throw new Error("KEY_IDENTITY_NOT_CONFIRMED");
  const response = await request("api_keys", "POST", {
    name: `Duindorp Halloween verified mail repair ${process.env.GITHUB_RUN_ID}`,
    scopes: restoredMailScopes(metadata.scopes),
  });
  if (!response.ok) throw new Error(`REPLACEMENT_KEY_CREATION_HTTP_${response.status}`);
  const created = await response.json();
  if (!created.api_key || !created.api_key_id) throw new Error("REPLACEMENT_KEY_NOT_CONFIRMED");
  let handedOff = false;
  try {
    let probe;
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt) await new Promise(resolve => setTimeout(resolve, 5_000));
      probe = await request("mail/send", "POST", {
        personalizations: [{ to: [{ email: process.env.SENDGRID_FROM_EMAIL }] }],
        from: { email: process.env.SENDGRID_FROM_EMAIL }, subject: "Mailgatewaycontrole",
        content: [{ type: "text/plain", value: "Runtimecontrole zonder aflevering." }],
        mail_settings: { sandbox_mode: { enable: true } },
      }, created.api_key);
      if (probe.status === 200) break;
      await probe.body?.cancel();
    }
    if (probe.status !== 200) throw new Error(`REPLACEMENT_KEY_SEND_REFUSED_HTTP_${probe.status}`);
    const encrypted = publicEncrypt({ key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" },
      Buffer.from(JSON.stringify({ api_key: created.api_key, api_key_id: created.api_key_id })));
    console.log(JSON.stringify({ replacementMailValidated: true, encryptedCredential: encrypted.toString("base64") }));
    handedOff = true;
  } finally {
    if (!handedOff) {
      const removed = await request(`api_keys/${created.api_key_id}`, "DELETE");
      if (!removed.ok) throw new Error(`REPLACEMENT_CLEANUP_HTTP_${removed.status}`);
      console.log(JSON.stringify({ unusableReplacementRemoved: true }));
    }
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
