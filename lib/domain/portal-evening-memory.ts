import { createSimulation, type SimulationState } from "./portal-evening-model";

// Fictional state only. Reloading/closing the tab clears this module's memory.
// No localStorage, account store, command queue or cross-device synchronization.
const namespace = "duindorp.portal-practice.memory.v1:";
const exercises = new Map<string, SimulationState>();
export function readPractice(scope: string) {
  return typeof window === "undefined"
    ? createSimulation()
    : (exercises.get(namespace + scope) ?? createSimulation());
}
export function rememberPractice(scope: string, state: SimulationState) {
  if (typeof window === "undefined") return;
  exercises.delete(namespace + scope);
  exercises.set(namespace + scope, state);
  while (exercises.size > 8) exercises.delete(exercises.keys().next().value!);
}
