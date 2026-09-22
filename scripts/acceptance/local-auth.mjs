import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_ANON_KEY;
const mailpitUrl = process.env.MAILPIT_URL;
if (!url || !key || !mailpitUrl) throw new Error("Local Supabase and Mailpit configuration are required");

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function latestMessage(email) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const response = await fetch(`${mailpitUrl}/api/v1/search?query=${encodeURIComponent(`to:\"${email}\"`)}`);
    const search = await response.json();
    if (search.messages?.[0]) return fetch(`${mailpitUrl}/api/v1/message/${search.messages[0].ID}`).then((item) => item.json());
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Local OTP message was not captured by Mailpit");
}

async function latestMessageMatching(email, pattern) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const response = await fetch(`${mailpitUrl}/api/v1/search?query=${encodeURIComponent(`to:"${email}"`)}`);
    const search = await response.json();
    for (const summary of search.messages ?? []) {
      const message = await fetch(`${mailpitUrl}/api/v1/message/${summary.ID}`).then((item) => item.json());
      if (pattern.test(`${message.Text ?? ""}\n${message.HTML ?? ""}`)) return message;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Expected local Auth message was not captured for ${email}`);
}

function tokenHashFrom(message) {
  return String(`${message.Text ?? ""}\n${message.HTML ?? ""}`).match(/[?&](?:token|token_hash)=([^&\s"'<>)]+)/)?.[1];
}

function verificationTypeFrom(message) {
  return String(`${message.Text ?? ""}\n${message.HTML ?? ""}`).match(/[?&]type=([^&\s"'<>)]+)/)?.[1]?.replaceAll("&amp;", "");
}

const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const forgedResponse = await fetch(`${url}/rest/v1/rpc/my_context`, {
  method: "POST",
  headers: { apikey: key, authorization: "Bearer eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJmMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEiLCJyb2xlIjoiYXV0aGVudGljYXRlZCJ9." , "content-type": "application/json" },
  body: JSON.stringify({ _event_slug: "duindorp-halloween-2026" }),
});
check(forgedResponse.status === 401, "a forged session token reached a protected projection");

const email = `auth-acceptance-${Date.now()}@example.invalid`;
let response = await client.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
check(!response.error, `local OTP request failed: ${response.error?.code ?? response.error?.message}`);

const throttled = await client.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
check(Boolean(throttled.error), "immediate OTP resend was not rate limited");

const message = await latestMessage(email);
const tokenHash = String(message.Text ?? "").match(/[?&]token=([^&\s)]+)/)?.[1];
const verificationType = verificationTypeFrom(message);
check(tokenHash, "local one-time login message did not contain a token hash");
check(["signup", "magiclink"].includes(verificationType), "local one-time login message had an unexpected verification type");
const wrongTokenHash = tokenHash.replace(/^./, tokenHash.startsWith("0") ? "1" : "0");

response = await client.auth.verifyOtp({ token_hash: wrongTokenHash, type: verificationType });
check(Boolean(response.error) && !response.data.session, "an incorrect OTP unexpectedly created a session");

response = await client.auth.verifyOtp({ token_hash: tokenHash, type: verificationType });
check(!response.error && response.data.session?.user.email === email, "the valid OTP did not create the intended session");
const firstUserId = response.data.user.id;
const refreshedSession = await client.auth.refreshSession();
check(!refreshedSession.error && refreshedSession.data.user?.id === firstUserId && refreshedSession.data.session?.access_token, "session refresh did not preserve the authenticated identity");

const replayClient = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const replay = await replayClient.auth.verifyOtp({ token_hash: tokenHash, type: verificationType });
check(Boolean(replay.error) && !replay.data.session, "a consumed OTP could be reused");

const draft = await client.schema("api").rpc("registration_save_draft", {
  _event_slug: "duindorp-halloween-2026",
  _payload: {
    adult: { name: "Nieuwe testouder", householdLabel: "OTP testgezin", phone: "0612345678" },
    children: [{ name: "Conceptkind", age: "8", accessibilityNote: "" }],
    marketingConsent: false,
  },
  _expected_version: null,
});
check(!draft.error && draft.data?.id, "a genuine new OTP account could not start an open parent registration");

const changedEmail = `auth-changed-${Date.now()}@example.invalid`;
const emailChange = await client.auth.updateUser({ email: changedEmail });
check(!emailChange.error && emailChange.data.user?.new_email === changedEmail, "secure email change did not remain pending for dual confirmation");
const [oldAddressMessage, newAddressMessage] = await Promise.all([
  latestMessageMatching(email, /type=email_change/),
  latestMessageMatching(changedEmail, /type=email_change/),
]);
const oldAddressToken = tokenHashFrom(oldAddressMessage);
const newAddressToken = tokenHashFrom(newAddressMessage);
check(oldAddressToken && newAddressToken && oldAddressToken !== newAddressToken, "dual email change did not issue distinct address-bound tokens");
const newAddressConfirmation = await client.auth.verifyOtp({ token_hash: newAddressToken, type: "email_change" });
check(!newAddressConfirmation.error, "the new address could not approve the secure email change");
const oldAddressConfirmation = await client.auth.verifyOtp({ token_hash: oldAddressToken, type: "email_change" });
check(!oldAddressConfirmation.error && oldAddressConfirmation.data.user?.email === changedEmail, "both address confirmations did not complete the secure email change");
const emailChangeReplay = await client.auth.verifyOtp({ token_hash: oldAddressToken, type: "email_change" });
check(Boolean(emailChangeReplay.error), "an email-change confirmation token could be replayed");

response = await client.auth.signOut();
check(!response.error, "logout failed");
const signedOut = await client.auth.getSession();
check(!signedOut.data.session, "logout left an active session behind");

const otherAccount = await client.auth.signInWithPassword({ email: "parent-b@example.invalid", password: "local-test-only" });
check(!otherAccount.error && otherAccount.data.user?.email === "parent-b@example.invalid", "account switch did not establish the second identity");
check(otherAccount.data.user.id !== firstUserId, "account switch retained the previous user identity");

console.log(JSON.stringify({ status: "pass", checks: ["AUTH-02", "AUTH-03", "AUTH-04", "AUTH-05", "AUTH-07", "AUTH-10", "AUTH-11", "MAIL-17"] }));
