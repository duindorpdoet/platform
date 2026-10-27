"use client";
import { useSyncExternalStore } from "react";

export type InstallPrompt = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: "accepted" | "dismissed" }> };
type InstallState = { ready: boolean; installed: boolean; prompt: InstallPrompt | null };
const empty: InstallState = { ready: false, installed: false, prompt: null };
let state = empty;
const listeners = new Set<() => void>();
export const deviceStorage = {
  getItem(key: string) { try { return localStorage.getItem(key); } catch { return null; } },
  setItem(key: string, value: string) { try { localStorage.setItem(key, value); } catch { /* Optional device preference. */ } },
};
export function isStandalone() { return typeof window !== "undefined" && (window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true); }
export function isAppleMobile(platform: Pick<Navigator, "userAgent" | "platform" | "maxTouchPoints"> = navigator) {
  return /iPhone|iPad|iPod/i.test(platform.userAgent) || (platform.platform === "MacIntel" && platform.maxTouchPoints > 1);
}
function update(next: InstallState) { state = next; for (const listener of listeners) listener(); }
// Capture before the asynchronous account/guidance screens are hydrated.
if (typeof window !== "undefined") {
  state = { ready: true, installed: isStandalone(), prompt: null };
  window.addEventListener("beforeinstallprompt", event => { event.preventDefault(); update({ ...state, prompt: event as InstallPrompt }); });
  window.addEventListener("appinstalled", () => update({ ready: true, installed: true, prompt: null }));
  window.matchMedia("(display-mode: standalone)").addEventListener?.("change", () => update({ ...state, installed: isStandalone() }));
}
export function useInstallRuntime() {
  return useSyncExternalStore(listener => { listeners.add(listener); return () => listeners.delete(listener); }, () => state, () => empty);
}
export function consumeInstallPrompt() { const prompt = state.prompt; update({ ...state, prompt: null }); return prompt; }
export async function endpointHash(endpoint: string) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(endpoint));
  return [...new Uint8Array(bytes)].map(value => value.toString(16).padStart(2, "0")).join("");
}
