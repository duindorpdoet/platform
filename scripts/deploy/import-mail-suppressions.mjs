import { mailRpc } from "./mail-service.mjs";
import { SuppressionSyncError, syncSendGridSuppressions } from "./sendgrid-suppressions.mjs";

try {
  const counts = await syncSendGridSuppressions({
    environment: process.env.APP_ENVIRONMENT,
    apiKey: process.env.SENDGRID_SUPPRESSIONS_API_KEY || process.env.SENDGRID_API,
    apiBaseUrl: process.env.SENDGRID_API_BASE_URL,
    rpc: mailRpc,
  });
  console.log(`SendGrid suppressions automatically imported: ${JSON.stringify(counts)}. No consent was restored.`);
} catch (error) {
  const code = error instanceof SuppressionSyncError ? error.message : "SUPPRESSION_IMPORT_STORAGE_FAILED";
  console.error(`${code}: automatic suppression import could not be confirmed; activation requires a confirmed complete import.`);
  if (code === "SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED") {
    console.error("Grant suppression-list read access to the existing deployment credential, or configure SENDGRID_SUPPRESSIONS_API_KEY as a separate read-only environment secret for the same sending account. No export file is needed.");
  }
  process.exitCode = 1;
}
