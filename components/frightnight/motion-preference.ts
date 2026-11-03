"use client";

import { useEffect, useSyncExternalStore } from "react";

// A public display preference, independent of accounts and event authority.
const key = "frightnight-calm-v1";
const changed = "frightnight:motion-preference";
let volatileChoice: boolean | undefined;

function readChoice() {
  if (volatileChoice !== undefined) return volatileChoice;
  try { return window.localStorage.getItem(key) === "1"; }
  catch { return false; }
}

function subscribeChoice(notify: () => void) {
  const storage = (event: StorageEvent) => {
    if (event.key === key || event.key === null) { volatileChoice = undefined; notify(); }
  };
  window.addEventListener("storage", storage);
  window.addEventListener(changed, notify);
  return () => { window.removeEventListener("storage", storage); window.removeEventListener(changed, notify); };
}

function setChoice(calm: boolean) {
  try { window.localStorage.setItem(key, calm ? "1" : "0"); volatileChoice = undefined; }
  catch { volatileChoice = calm; }
  window.dispatchEvent(new Event(changed));
}

function systemChoice() { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; }
function subscribeSystem(notify: () => void) {
  const query = window.matchMedia("(prefers-reduced-motion: reduce)");
  query.addEventListener("change", notify);
  return () => query.removeEventListener("change", notify);
}
const serverChoice = () => false;
const serverCalm = () => true;

export function useCalmPreference() {
  const paused = useSyncExternalStore(subscribeChoice, readChoice, serverChoice);
  // Start SSR quietly; the stable server snapshot never reads browser storage.
  const system = useSyncExternalStore(subscribeSystem, systemChoice, serverCalm);
  const calm = system || paused;
  useEffect(() => { document.documentElement.classList.toggle("fn-calm", calm); }, [calm]);
  return { calm, paused, system, setPaused: setChoice };
}
