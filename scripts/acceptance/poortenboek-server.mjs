// Local HTTPS is intentional: do not weaken Secure/__Host cookies for browser tests.
import { createServer } from "node:https";
import { request } from "node:http";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { requireLocalTogetherDatabase } from "./together-fixtures.mjs";

requireLocalTogetherDatabase();
const directory = mkdtempSync(join(tmpdir(), "poortenboek-https-"));
const key = join(directory, "key.pem"),
  cert = join(directory, "cert.pem");
execFileSync(
  "openssl",
  [
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    key,
    "-out",
    cert,
    "-days",
    "1",
    "-subj",
    "/CN=127.0.0.1",
    "-addext",
    "subjectAltName=IP:127.0.0.1",
  ],
  { stdio: "ignore" },
);
const app = spawn("pnpm", ["start", "--port", "3100"], {
  stdio: "inherit",
  env: {
    ...process.env,
    APP_URL: "https://127.0.0.1:3443",
    ALLOWED_ORIGINS: "https://127.0.0.1:3443,http://127.0.0.1:3100",
    NODE_EXTRA_CA_CERTS: cert,
  },
});
// WebKit rejects an HTTP Supabase API from an HTTPS parent dashboard.
// The dedicated test build points its public Supabase URL at this TLS relay.
const localApi = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL);
const database = createServer(
  { key: readFileSync(key), cert: readFileSync(cert) },
  (incoming, response) => {
    const upstream = request(
      {
        hostname: localApi.hostname,
        port: localApi.port,
        path: incoming.url,
        method: incoming.method,
        headers: { ...incoming.headers, host: localApi.host },
      },
      (result) => {
        response.writeHead(result.statusCode ?? 502, result.headers);
        result.pipe(response);
      },
    );
    upstream.on("error", () => {
      response.writeHead(503);
      response.end("Local API unavailable");
    });
    incoming.pipe(upstream);
  },
);
database.listen(3444, "127.0.0.1");
const server = createServer(
  { key: readFileSync(key), cert: readFileSync(cert) },
  (incoming, response) => {
    const upstream = request(
      {
        hostname: "127.0.0.1",
        port: 3100,
        path: incoming.url,
        method: incoming.method,
        headers: {
          ...incoming.headers,
          "x-forwarded-proto": "https",
          "x-real-ip": "127.0.0.1",
          "x-forwarded-for": "127.0.0.1",
        },
      },
      (result) => {
        response.writeHead(result.statusCode ?? 502, result.headers);
        result.pipe(response);
      },
    );
    upstream.on("error", () => {
      response.writeHead(503);
      response.end("Starting local application");
    });
    incoming.pipe(upstream);
  },
);
server.listen(3443, "127.0.0.1");
function close() {
  server.close();
  database.close();
  app.kill("SIGTERM");
  rmSync(directory, { recursive: true, force: true });
}
process.on("SIGTERM", close);
process.on("SIGINT", close);
