import { StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { Poortenboek } from "../../components/poortenboek/book";
import { KidGuide } from "../../components/poortenboek/kid-guide";
import { bookIdentityKey, saveConfirmedBookIdentity } from "../../components/redesign/book-identity-check";
import { bookFixture } from "./fixture";

export type Plan = {
  status?: number;
  headers?: Record<string, string>;
  holdHeaders?: boolean;
  holdBody?: boolean;
  ignoreAbort?: boolean;
  networkError?: boolean;
  data?: unknown;
};
type RecordEntry = {
  id: number; url: string; method: string; at: number;
  phase: "headers" | "body" | "done"; aborted: boolean;
  hasSignal: boolean; body: string | null; endedAt?: number;
};
type Gate = { promise: Promise<void>; resolve: () => void; reject: (reason: unknown) => void };
function gate(): Gate {
  let resolve!: Gate["resolve"], reject!: Gate["reject"];
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const readPlans: Plan[] = [], mutationPlans: Plan[] = [];
const records: RecordEntry[] = [];
const pending = new Map<number, { headers: Gate; body: Gate }>();
let serverSnapshot = bookFixture();
let root: Root | null = null;
let hidden = false, online = true;
let readActive = 0, maxReadActive = 0;
Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
Object.defineProperty(navigator, "onLine", { configurable: true, get: () => online });
Math.random = () => 0;

const originalFetch = window.fetch.bind(window);
window.fetch = async (input, options) => {
  const url = String(input);
  if (!url.startsWith("/api/poortenboek/")) return originalFetch(input, options);
  const method = options?.method ?? "GET";
  const read = method === "GET";
  const plan = (read ? readPlans : mutationPlans).shift() ?? {};
  const record: RecordEntry = {
    id: records.length, url, method, at: Date.now(), phase: "headers", aborted: false,
    hasSignal: Boolean(options?.signal), body: typeof options?.body === "string" ? options.body : null,
  };
  records.push(record);
  if (read) { readActive++; maxReadActive = Math.max(maxReadActive, readActive); }
  let done = false;
  const finish = () => {
    if (done) return;
    done = true; record.phase = "done"; record.endedAt = Date.now();
    if (read) readActive--;
    pending.delete(record.id);
    options?.signal?.removeEventListener("abort", abort);
  };
  const headers = gate(), body = gate();
  // A rejected gate may precede its await when headers are held.
  void headers.promise.catch(() => {}); void body.promise.catch(() => {});
  pending.set(record.id, { headers, body });
  const abort = () => {
    record.aborted = true;
    if (plan.ignoreAbort) return;
    headers.reject(new DOMException("Aborted", "AbortError"));
    body.reject(new DOMException("Aborted", "AbortError"));
    finish();
  };
  options?.signal?.addEventListener("abort", abort, { once: true });
  if (options?.signal?.aborted) abort();
  const data = plan.data === undefined ? structuredClone(serverSnapshot) : plan.data;
  if (!plan.holdHeaders) headers.resolve();
  if (!plan.holdBody) body.resolve();
  try {
    await headers.promise;
    if (plan.networkError) throw new TypeError("Synthetic network failure");
    const response = new Response(null, { status: plan.status ?? 200, headers: plan.headers });
    if (!response.ok) finish();
    response.json = async () => {
      record.phase = "body";
      try { await body.promise; return structuredClone(data); }
      finally { finish(); }
    };
    return response;
  } catch (error) { finish(); throw error; }
};

async function renderBook(childId = "child-a", firstName = "Mila", expiresAt?: string) {
  serverSnapshot = bookFixture(childId, firstName);
  if (expiresAt) serverSnapshot.expiresAt = expiresAt;
  saveConfirmedBookIdentity(await bookIdentityKey(serverSnapshot));
  root ??= createRoot(document.getElementById("root")!);
  root.render(<StrictMode><Poortenboek initial={serverSnapshot} section="nu"/></StrictMode>);
}
const guideRequest = async () => null;
let guideSnapshot = bookFixture();

window.__poortenboekTest = {
  ready: false,
  queueRead: (...plans) => { readPlans.push(...plans); },
  queueMutation: (...plans) => { mutationPlans.push(...plans); },
  stats: () => ({ records: structuredClone(records), readActive, maxReadActive }),
  releaseHeaders: id => { pending.get(id)?.headers.resolve(); },
  releaseBody: id => { pending.get(id)?.body.resolve(); },
  hidden(value) {
    hidden = value;
    document.dispatchEvent(new Event("visibilitychange"));
  },
  online(value) {
    online = value;
    window.dispatchEvent(new Event(value ? "online" : "offline"));
  },
  burst() {
    for (let i = 0; i < 20; i++) {
      window.dispatchEvent(new Event("focus"));
      window.dispatchEvent(new Event("online"));
    }
  },
  renderBook,
  unmount() { root?.unmount(); root = null; },
  renderUnavailableGuide() {
    root?.unmount(); root = createRoot(document.getElementById("root")!);
    window.history.replaceState(null, "", "/poortenboek");
    guideSnapshot = { ...bookFixture(), tutorial: { version: 1, completedAt: null, lastStep: 0 } };
    root.render(<StrictMode><KidGuide snapshot={guideSnapshot} section="nu" requestSnapshot={guideRequest}/></StrictMode>);
  },
  freshGuideSnapshot() {
    guideSnapshot = { ...guideSnapshot, updatedAt: new Date().toISOString() };
    root?.render(<StrictMode><KidGuide snapshot={guideSnapshot} section="nu" requestSnapshot={guideRequest}/></StrictMode>);
  },
};

export type Harness = {
  ready: boolean;
  queueRead: (...plans: Plan[]) => void;
  queueMutation: (...plans: Plan[]) => void;
  stats: () => { records: RecordEntry[]; readActive: number; maxReadActive: number };
  releaseHeaders: (id: number) => void;
  releaseBody: (id: number) => void;
  hidden: (value: boolean) => void;
  online: (value: boolean) => void;
  burst: () => void;
  renderBook: (childId?: string, firstName?: string, expiresAt?: string) => Promise<void>;
  unmount: () => void;
  renderUnavailableGuide: () => void;
  freshGuideSnapshot: () => void;
};
declare global { interface Window { __poortenboekTest: Harness } }

await renderBook();
window.__poortenboekTest.ready = true;
