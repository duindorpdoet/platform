/** Serialize read-only preflights; identical pending requests share one result. */
export function createSerialRead() {
  let tail: Promise<unknown> = Promise.resolve();
  const pending = new Map<string, Promise<unknown>>();
  return {
    run<T>(key: string, read: () => Promise<T>): Promise<T> {
      const existing = pending.get(key);
      if (existing) return existing as Promise<T>;
      const result = tail.then(read, read);
      pending.set(key, result);
      tail = result.then(() => undefined, () => undefined);
      const clear = () => { if (pending.get(key) === result) pending.delete(key); };
      void result.then(clear, clear);
      return result;
    },
  };
}
