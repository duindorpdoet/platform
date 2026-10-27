import { createHash } from "node:crypto";

const sources = [
  ["unsubscribe", "unsubscribes"],
  ["invalid", "invalid_emails"],
  ["bounce", "bounces"],
  ["spamreport", "spam_reports"],
];
const pageSize = 500;
const maxPages = 1000;
const maxBodyBytes = 2 * 1024 * 1024;
const allowedBases = new Set(["https://api.sendgrid.com/v3", "https://api.eu.sendgrid.com/v3"]);
const digest = value => createHash("sha256").update(value).digest("hex");

export class SuppressionSyncError extends Error {}
const failure = code => new SuppressionSyncError(code);

async function readPage(response) {
  if (!response.body) throw failure("SENDGRID_SUPPRESSIONS_INVALID_RESPONSE");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBodyBytes) {
        await reader.cancel();
        throw failure("SENDGRID_SUPPRESSIONS_RESPONSE_TOO_LARGE");
      }
      chunks.push(value);
    }
    const page = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!Array.isArray(page) || page.length > pageSize) throw failure("SENDGRID_SUPPRESSIONS_INVALID_RESPONSE");
    return page;
  } catch (error) {
    if (error instanceof SuppressionSyncError) throw error;
    throw failure("SENDGRID_SUPPRESSIONS_INVALID_RESPONSE");
  } finally {
    reader.releaseLock();
  }
}

function retryDelay(response, attempt) {
  const header = response?.headers.get("retry-after");
  const seconds = header && /^\d+(?:\.\d+)?$/.test(header) ? Number(header) : NaN;
  const wait = Number.isFinite(seconds) ? seconds * 1000 : header ? Date.parse(header) - Date.now() : 500 * 2 ** attempt;
  return Math.min(5000, Math.max(0, Number.isFinite(wait) ? wait : 500 * 2 ** attempt));
}

/** Read-only provider requests; only recipient hashes leave this process. */
export async function syncSendGridSuppressions({
  environment,
  apiKey,
  apiBaseUrl = "https://api.sendgrid.com/v3",
  rpc,
  fetchImpl = fetch,
  pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
}) {
  if (!["staging", "production"].includes(environment)) throw failure("SUPPRESSION_ENVIRONMENT_REQUIRED");
  if (!apiKey) throw failure("SENDGRID_SUPPRESSIONS_CREDENTIAL_MISSING");
  if (!allowedBases.has(apiBaseUrl)) throw failure("SENDGRID_SUPPRESSIONS_ENDPOINT_INVALID");
  const endTime = Math.floor(Date.now() / 1000);
  const deadline = Date.now() + 5 * 60 * 1000;
  const source = JSON.stringify({ source: "sendgrid-suppressions-v3", environment, apiBaseUrl, endTime });
  const pendingHash = digest(source);
  const fingerprint = createHash("sha256").update(source);
  const counts = {};

  async function getPage(url) {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (Date.now() >= deadline) throw failure("SENDGRID_SUPPRESSIONS_TIME_LIMIT");
      let response;
      try {
        response = await fetchImpl(url, {
          method: "GET", redirect: "error", cache: "no-store",
          headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
          signal: AbortSignal.timeout(10000),
        });
      } catch {
        if (attempt === 2) throw failure("SENDGRID_SUPPRESSIONS_UNAVAILABLE");
      }
      if (response?.status === 200) return readPage(response);
      const status = response?.status;
      // Never log a provider error body, which can contain recipient data.
      await response?.body?.cancel();
      if (status === 401 || status === 403) throw failure("SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED");
      if (status && status !== 429 && status < 500) throw failure(`SENDGRID_SUPPRESSIONS_HTTP_${status}`);
      if (attempt === 2) throw failure(status === 429 ? "SENDGRID_SUPPRESSIONS_RATE_LIMITED" : "SENDGRID_SUPPRESSIONS_UNAVAILABLE");
      await pause(retryDelay(response, attempt));
    }
  }

  for (const [reason, list] of sources) {
    let offset = 0;
    let completed = false;
    const seenPages = new Set();
    counts[reason] = 0;
    for (let pageNumber = 0; pageNumber < maxPages; pageNumber++) {
      const url = new URL(`${apiBaseUrl}/suppression/${list}`);
      url.search = new URLSearchParams({ limit: String(pageSize), offset: String(offset), start_time: "0", end_time: String(endTime) }).toString();
      const page = await getPage(url);
      if (page.length === 0) { completed = true; break; }
      const unique = new Map();
      for (const entry of page) {
        // The invalid-email source can legitimately contain malformed addresses.
        // Preserve their hashes too instead of blocking migration or dropping them.
        if (!entry || typeof entry.email !== "string" || !entry.email.trim() || entry.email.length > 320 || (reason !== "invalid" && !/^\S+@\S+\.\S+$/.test(entry.email.trim()))) {
          throw failure("SENDGRID_SUPPRESSIONS_INVALID_RECIPIENT");
        }
        const emailHash = digest(entry.email.trim().toLowerCase());
        unique.set(emailHash, { emailHash, reason });
      }
      const entries = [...unique.values()].sort((a, b) => a.emailHash.localeCompare(b.emailHash));
      const pageHash = digest(JSON.stringify(entries));
      if (seenPages.has(pageHash)) throw failure("SENDGRID_SUPPRESSIONS_PAGINATION_REPEATED");
      seenPages.add(pageHash);
      fingerprint.update(JSON.stringify([reason, offset, pageHash]));
      await rpc("worker_import_mail_suppressions", { _environment: environment, _entries: entries, _source_hash: pendingHash, _complete: false });
      counts[reason] += entries.length;
      offset += page.length;
    }
    if (!completed) throw failure("SENDGRID_SUPPRESSIONS_PAGINATION_LIMIT");
  }
  // A genuine empty account is valid only after successful reads of every list.
  // Partial imports remain protective, but never satisfy the activation gate.
  await rpc("worker_import_mail_suppressions", { _environment: environment, _entries: [], _source_hash: fingerprint.digest("hex"), _complete: true });
  return counts;
}
