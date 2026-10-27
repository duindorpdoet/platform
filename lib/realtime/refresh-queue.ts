/** A queue for snapshot reads only. Commands and arrival retries must bypass it. */
export function createRefreshQueue(refresh: () => void | Promise<unknown>, delay = () => 250 + Math.floor(Math.random() * 250)) {
  type Waiter = { resolve: () => void; reject: (error: unknown) => void };
  let timer: ReturnType<typeof setTimeout> | undefined;
  let running = false;
  let pending = false;
  let immediate = false;
  let disposed = false;
  let waiters: Waiter[] = [];

  const schedule = () => {
    if (disposed || running || !pending || timer !== undefined) return;
    // A fixed window cannot be postponed by a continuous stream of broadcasts.
    timer = setTimeout(() => { timer = undefined; void run(); }, delay());
  };
  const run = async () => {
    if (disposed || running || !pending) return;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    const current = waiters;
    waiters = [];
    pending = false;
    immediate = false;
    running = true;
    try {
      await refresh();
      current.forEach(waiter => waiter.resolve());
    } catch (error) {
      current.forEach(waiter => waiter.reject(error));
      // Background reads have no caller; the source owns its error/freshness UI.
    } finally {
      running = false;
      if (pending && !disposed) {
        if (immediate) void run();
        else schedule();
      }
    }
  };

  return {
    /** Broadcasts share one read, including one follow-up after an in-flight read. */
    invalidate() {
      if (disposed) return;
      pending = true;
      schedule();
    },
    /** Manual/post-command reads wait for a fresh read after an older in-flight one. */
    load(): Promise<void> {
      if (disposed) return Promise.resolve();
      pending = true;
      immediate = true;
      const result = new Promise<void>((resolve, reject) => { waiters.push({ resolve, reject }); });
      void run();
      return result;
    },
    dispose() {
      disposed = true;
      pending = false;
      if (timer !== undefined) clearTimeout(timer);
      waiters.forEach(waiter => waiter.resolve());
      waiters = [];
    },
  };
}

/** Spread fallback reads; never increase their frequency as requests slow down. */
export function snapshotPollDelay(intervalMs: number, random = Math.random()) {
  return intervalMs + Math.floor(intervalMs * .2 * random);
}
