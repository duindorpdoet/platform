import { describe, expect, it, vi, afterEach } from "vitest";
import {
  createSimulation,
  nextSimulationStep,
  simulationReducer as reduce,
  simulationSteps,
  type SimulationState,
  type SimulationAction,
} from "./portal-evening-model";
import { readPractice, rememberPractice } from "./portal-evening-memory";

const apply = (state: SimulationState, ...actions: SimulationAction[]) =>
  actions.reduce(reduce, state);
const open = () =>
  apply(createSimulation(), { type: "START" }, { type: "OPEN" });
const arrive = (state: SimulationState) =>
  Array.from({ length: 10 }).reduce<SimulationState>(
    (s) => reduce(s, { type: "TICK" }),
    state,
  );
afterEach(() => vi.unstubAllGlobals());

describe("fictional portal rehearsal", () => {
  it("does not act before start or invent checkpoints", () => {
    const initial = createSimulation();
    for (const action of [
      { type: "OPEN" },
      { type: "CONFIRM_ARRIVAL" },
      { type: "CROWD" },
      { type: "FINALE" },
    ] as SimulationAction[])
      expect(reduce(initial, action)).toBe(initial);
    const state = apply(
      open(),
      { type: "CONFIRM_ARRIVAL" },
      { type: "FINISH_VISIT" },
    );
    expect(state.completed).toEqual(["open"]);
    expect(state.visits + state.children + state.seals).toBe(0);
  });
  it("requires explicit arrival and completion, with no duplicate counts or seals", () => {
    const onWay = reduce(open(), { type: "SEND_GROUP" });
    expect(reduce(onWay, { type: "CONFIRM_ARRIVAL" }).visits).toBe(0);
    const atGate = arrive(onWay);
    expect(atGate.groups[0].status).toBe("arrived");
    expect(atGate.visits).toBe(0);
    const received = reduce(atGate, {
      type: "CONFIRM_ARRIVAL",
      groupId: atGate.groups[0].id,
    });
    expect(received.visits).toBe(1);
    expect(received.children).toBe(12);
    expect(received.seals).toBe(0);
    expect(reduce(received, { type: "CONFIRM_ARRIVAL" })).toBe(received);
    expect(
      reduce(received, { type: "FINISH_VISIT", groupId: "another-group" }),
    ).toBe(received);
    const done = reduce(received, { type: "FINISH_VISIT" });
    expect(done.seals).toBe(12);
    expect(reduce(done, { type: "FINISH_VISIT" })).toBe(done);
    expect(received.groups[0].status).toBe("inside");
  });
  it("pauses new inflow, preserves the current group and resumes the waiting group", () => {
    let state = apply(
      arrive(reduce(open(), { type: "CROWD" })),
      { type: "CONFIRM_ARRIVAL" },
      { type: "PAUSE" },
    );
    expect(state.groups.map((g) => g.status)).toEqual(["inside", "waiting"]);
    state = reduce(state, { type: "FINISH_VISIT" });
    expect(state.groups.map((g) => g.status)).toEqual(["done", "waiting"]);
    expect(reduce(state, { type: "SEND_GROUP" }).groups).toEqual(state.groups);
    state = reduce(state, { type: "RESUME" });
    expect(state.groups.map((g) => g.status)).toEqual(["done", "approaching"]);
    expect(state.completed).toContain("resume");
    expect(state.visits).toBe(1);
  });
  it("keeps crowding bounded to three pending groups and one reception", () => {
    let state = apply(
      open(),
      { type: "CROWD" },
      { type: "CROWD" },
      { type: "CROWD" },
    );
    expect(state.groups).toHaveLength(3);
    expect(state.groups.filter((g) => g.status === "approaching")).toHaveLength(
      1,
    );
    state = apply(arrive(state), { type: "CONFIRM_ARRIVAL" });
    expect(state.groups.filter((g) => g.status === "inside")).toHaveLength(1);
    expect(state.completed).toContain("crowd");
    expect(reduce(state, { type: "CLOSE" }).gate).toBe("open");
  });
  it("makes messages, help and finale local model results only", () => {
    let state = open();
    expect(reduce(state, { type: "MESSAGE", text: "   " })).toBe(state);
    state = reduce(state, {
      type: "MESSAGE",
      text: "  Het is druk bij de oefenpoort  ",
    });
    expect(state.message).toBe("Het is druk bij de oefenpoort");
    expect(state.helpReply).toContain("Fictieve regie");
    expect(reduce(state, { type: "HELP" }).completed).toContain("message");
    expect(reduce(state, { type: "FINALE" }).finale).toBe(false);
    expect(state.visits + state.seals).toBe(0);
  });
  it("finishes the guided route through actual actions, including resume and every queued group", () => {
    let state = reduce(createSimulation(), { type: "START" });
    for (let n = 0; n < 100 && !state.completed.includes("finish"); n++) {
      const step = nextSimulationStep(state)!;
      let action = step.action;
      if (
        step.id === "arrived" &&
        !state.groups.some((g) => g.status === "arrived")
      )
        action = { type: "TICK" };
      if (step.id === "finish")
        action = state.groups.some((g) => g.status === "inside")
          ? { type: "FINISH_VISIT" }
          : state.groups.some((g) => g.status === "arrived")
            ? { type: "CONFIRM_ARRIVAL" }
            : state.groups.some((g) => g.status === "approaching")
              ? { type: "TICK" }
              : state.groups.some((g) => g.status === "waiting")
                ? { type: "SEND_GROUP" }
                : { type: "CLOSE" };
      state = reduce(state, action);
    }
    expect(state.completed).toEqual(simulationSteps.map((s) => s.id));
    expect(state.groups.every((g) => g.status === "done")).toBe(true);
    expect(state.gate).toBe("closed");
    expect(state.visits).toBe(3);
    expect(state.children).toBe(30);
    expect(state.seals).toBe(30);
    const finale = reduce(state, { type: "FINALE" });
    expect(finale.finale).toBe(true);
    expect(reduce(finale, { type: "FINALE" })).toBe(finale);
    expect(reduce(finale, { type: "RESET" })).toEqual(createSimulation());
  });
  it("distinguishes pausing animation from pausing the gate and lets free mode resume", () => {
    const state = apply(
      open(),
      { type: "MODE", mode: "free" },
      { type: "SEND_GROUP" },
      { type: "PLAY", running: false },
    );
    expect(reduce(state, { type: "TICK" })).toBe(state);
    const moving = apply(
      state,
      { type: "PLAY", running: true },
      { type: "SPEED", speed: 4 },
      { type: "TICK" },
    );
    expect(moving.groups[0].progress).toBe(40);
    expect(moving.visits).toBe(0);
    expect(reduce(moving, { type: "PAUSE" }).running).toBe(true);
  });
  it("retains only fictional per-event/portal/user memory across mounts and never server state", () => {
    vi.stubGlobal("window", {});
    const state = reduce(open(), { type: "CROWD" });
    rememberPractice("event:portal:user-a", state);
    expect(readPractice("event:portal:user-a")).toEqual(state);
    expect(readPractice("event:portal:user-b")).toEqual(createSimulation());
    expect(readPractice("event:another-portal:user-a")).toEqual(
      createSimulation(),
    );
    vi.stubGlobal("window", undefined);
    expect(readPractice("event:portal:user-a")).toEqual(createSimulation());
  });
});
