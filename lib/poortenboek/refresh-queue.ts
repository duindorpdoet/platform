export type RefreshResult<T> =
  | { kind: "success"; value: T }
  | { kind: "retry"; retryAfterMs?: number }
  | { kind: "stopped" }
  | { kind: "cancelled" };

type Options<T> = {
  run: (signal: AbortSignal) => Promise<RefreshResult<T>>;
  pollIntervalMs?: number | null;
  requestTimeoutMs?: number;
  random?: () => number;
};

type Waiter<T> = {
  promise: Promise<T | null>;
  resolve: (value: T | null) => void;
};
type ActiveRefresh<T> = {
  controller: AbortController;
  generation: number;
  waiter: Waiter<T> | null;
  timedOut: boolean;
  deadline: ReturnType<typeof setTimeout> | null;
};

/** One queue per mounted reader. Mutations must never use this queue or its signal. */
export class SnapshotRefreshQueue<T> {
  private readonly options: Options<T>;
  private readonly pollIntervalMs: number;
  private readonly requestTimeoutMs: number;
  private available = false;
  private polling: boolean;
  private terminal = false;
  private generation = 0;
  private failures = 0;
  private retryDue: number | null = null;
  private pollDue: number | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private active: ActiveRefresh<T> | null = null;
  private pending = false;
  private waiter: Waiter<T> | null = null;

  constructor(options: Options<T>) {
    this.options = options;
    this.pollIntervalMs = options.pollIntervalMs ?? 12_000;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 15_000;
    this.polling = options.pollIntervalMs !== null;
  }

  request(): Promise<T | null> {
    if (!this.available || this.terminal) return Promise.resolve(null);
    if (this.waiter) return this.waiter.promise;
    let resolve!: (value: T | null) => void;
    const result = new Promise<T | null>((resolvePromise) => { resolve = resolvePromise; });
    this.waiter = { promise: result, resolve };
    this.pending = true;
    this.schedule();
    return result;
  }

  setAvailable(available: boolean): Promise<T | null> | undefined {
    if (this.available === available) return;
    this.available = available;
    if (!available) {
      this.invalidate();
      return;
    }
    // Resume once, retaining any server/backoff deadline from before the pause.
    // Returning this same slot lets callers await resume without queuing a second read.
    return this.request();
  }

  setPolling(polling: boolean): void {
    this.polling = polling;
    if (!polling) this.pollDue = null;
    else if (!this.active && this.pollDue === null) this.pollDue = Date.now() + this.pollIntervalMs;
    this.schedule();
  }

  invalidate(): void {
    this.generation += 1;
    this.clearTimer();
    this.pollDue = null;
    this.pending = false;
    this.settlePending();
    if (this.active) {
      if (this.active.deadline !== null) clearTimeout(this.active.deadline);
      this.active.controller.abort();
      this.active.waiter?.resolve(null);
      this.active.waiter = null;
    }
  }

  /** Reversible for React Strict Mode's effect cleanup/setup cycle. */
  stop(): void {
    this.available = false;
    this.invalidate();
  }

  private clearTimer(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  private settlePending(): void {
    this.waiter?.resolve(null);
    this.waiter = null;
  }

  private schedule(): void {
    this.clearTimer();
    if (!this.available || this.terminal || this.active) return;
    const due = this.pending
      ? Math.max(Date.now(), this.retryDue ?? 0)
      : this.retryDue ?? (this.polling ? this.pollDue : null);
    if (due === null) return;
    const delay = Math.max(0, due - Date.now());
    if (delay === 0) {
      void this.refresh();
    } else {
      this.timer = setTimeout(() => {
        this.timer = null;
        void this.refresh();
      }, delay);
    }
  }

  private async refresh(): Promise<void> {
    if (!this.available || this.terminal || this.active) return;
    const active: ActiveRefresh<T> = {
      controller: new AbortController(),
      generation: this.generation,
      waiter: this.waiter,
      timedOut: false,
      deadline: null,
    };
    this.active = active;
    this.waiter = null;
    this.pending = false;
    this.retryDue = null;
    this.pollDue = null;
    active.deadline = setTimeout(() => {
      active.deadline = null;
      active.timedOut = true;
      active.controller.abort();
    }, this.requestTimeoutMs);

    let result: RefreshResult<T>;
    try {
      // run includes fetch, response body, validation and guarded state updates.
      // Abort is best effort: keep the guard until that whole operation settles.
      result = await this.options.run(active.controller.signal);
    } catch {
      result = { kind: "retry" };
    } finally {
      if (active.deadline !== null) clearTimeout(active.deadline);
    }
    this.active = null;

    if (active.generation !== this.generation || !this.available) {
      active.waiter?.resolve(null);
      this.schedule();
      return;
    }
    if (active.timedOut) result = { kind: "retry" };

    if (result.kind === "success") {
      this.failures = 0;
      this.retryDue = null;
      this.pollDue = Date.now() + this.pollIntervalMs;
      active.waiter?.resolve(result.value);
    } else if (result.kind === "retry") {
      const base = [5_000, 10_000, 20_000, 30_000][Math.min(this.failures, 3)];
      this.failures += 1;
      const random = Math.max(0, Math.min(1, (this.options.random ?? Math.random)()));
      const backoff = Math.min(30_000, base * (1 + random * 0.2));
      this.retryDue = Date.now() + Math.max(backoff, result.retryAfterMs ?? 0);
      active.waiter?.resolve(null);
    } else if (result.kind === "stopped") {
      this.terminal = true;
      this.pending = false;
      this.retryDue = null;
      this.pollDue = null;
      active.waiter?.resolve(null);
      this.settlePending();
    } else {
      this.pollDue = Date.now() + this.pollIntervalMs;
      active.waiter?.resolve(null);
    }
    this.schedule();
  }
}
