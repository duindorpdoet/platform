import { useSyncExternalStore } from "react";

const listeners = new Set<() => void>();
const router = {
  push(path: string) {
    window.history.pushState(null, "", path);
    listeners.forEach(listener => listener());
  },
};
export const useRouter = () => router;
export const usePathname = () => useSyncExternalStore(
  listener => { listeners.add(listener); return () => listeners.delete(listener); },
  () => window.location.pathname,
);
