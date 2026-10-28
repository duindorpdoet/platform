/** Browser-only, fictional training state. This model has no account or network access. */
export type SimulationGroup = {
  id: string;
  name: string;
  children: number;
  color: string;
  status: "waiting" | "approaching" | "arrived" | "inside" | "done";
  progress: number;
  sealed: boolean;
};
export type SimulationState = {
  started: boolean;
  mode: "guided" | "free";
  gate: "closed" | "open" | "paused";
  running: boolean;
  speed: 1 | 2 | 4;
  groups: SimulationGroup[];
  completed: string[];
  visits: number;
  children: number;
  /** Individual fictional child seals, awarded only after a visit is completed. */
  seals: number;
  clock: number;
  message: string;
  helpReply: string;
  log: Array<{ id: number; text: string; time: string }>;
  finale: boolean;
};
export type SimulationAction =
  | { type: "START" }
  | { type: "MODE"; mode: "guided" | "free" }
  | { type: "OPEN" }
  | { type: "SEND_GROUP" }
  | { type: "TICK" }
  | { type: "CONFIRM_ARRIVAL"; groupId?: string }
  | { type: "FINISH_VISIT"; groupId?: string }
  | { type: "CROWD" }
  | { type: "PAUSE" }
  | { type: "RESUME" }
  | { type: "MESSAGE"; text: string }
  | { type: "HELP" }
  | { type: "CLOSE" }
  | { type: "PLAY"; running: boolean }
  | { type: "SPEED"; speed: 1 | 2 | 4 }
  | { type: "FINALE" }
  | { type: "RESET" };
export type SimulationStep = {
  id: string;
  title: string;
  hint: string;
  actionLabel: string;
  action: SimulationAction;
};
export const simulationSteps: SimulationStep[] = [
  {
    id: "open",
    title: "Laat jullie poort stralen",
    hint: "Open de oefenpoort. Pas daarna kun je een fictieve groep laten vertrekken.",
    actionLabel: "Open de oefenpoort",
    action: { type: "OPEN" },
  },
  {
    id: "approaching",
    title: "De eerste groep is onderweg",
    hint: "Laat De Nachtlopers op pad gaan. Je ziet hun lantaarns langzaam dichterbij komen.",
    actionLabel: "Stuur een oefengroep",
    action: { type: "SEND_GROUP" },
  },
  {
    id: "arrived",
    title: "Een warm welkom",
    hint: "Wacht tot de groep bij de poort staat en bevestig dan zelf hun aankomst.",
    actionLabel: "Bevestig aankomst",
    action: { type: "CONFIRM_ARRIVAL" },
  },
  {
    id: "seal",
    title: "Een zegel voor het avontuur",
    hint: "Rond het oefenbezoek af. De fictieve kinderen krijgen ieder een oefenzegel en lopen verder.",
    actionLabel: "Rond bezoek af",
    action: { type: "FINISH_VISIT" },
  },
  {
    id: "crowd",
    title: "Het wordt gezellig druk",
    hint: "Voeg twee oefengroepen toe. Je ziet wie nadert en wie op zijn beurt wacht.",
    actionLabel: "Maak het wat drukker",
    action: { type: "CROWD" },
  },
  {
    id: "pause",
    title: "Even rustig aan",
    hint: "Zet de oefenpoort op pauze. Er vertrekt geen nieuwe groep; een al naderende groep kun je nog ontvangen en afronden.",
    actionLabel: "Pauzeer de oefenpoort",
    action: { type: "PAUSE" },
  },
  {
    id: "message",
    title: "Even contact met de regie",
    hint: "Probeer een lokaal oefenbericht of vraag hulp. Je ontvangt een duidelijk fictief regieantwoord.",
    actionLabel: "Probeer een hulpvraag",
    action: { type: "HELP" },
  },
  {
    id: "resume",
    title: "Samen weer op pad",
    hint: "Hervat de oefenpoort. Werk daarna ook de laatste wachtende oefengroepen rustig af.",
    actionLabel: "Hervat de oefenpoort",
    action: { type: "RESUME" },
  },
  {
    id: "finish",
    title: "Een fijne afsluiting",
    hint: "Ontvang ook de laatste wachtende groepen, rond hun bezoek af en sluit dan de oefenpoort.",
    actionLabel: "Sluit de oefenpoort",
    action: { type: "CLOSE" },
  },
];
export function nextSimulationStep(
  state: SimulationState,
): SimulationStep | undefined {
  return simulationSteps.find((step) => !state.completed.includes(step.id));
}
export function createSimulation(): SimulationState {
  return {
    started: false,
    mode: "guided",
    gate: "closed",
    running: true,
    speed: 1,
    groups: [],
    completed: [],
    visits: 0,
    children: 0,
    seals: 0,
    clock: 17 * 60,
    message: "",
    helpReply: "",
    log: [],
    finale: false,
  };
}
const groupIdeas = [
  { name: "De Nachtlopers", children: 12, color: "#f6bd69" },
  { name: "De Maanzoekers", children: 10, color: "#b4a1ff" },
  { name: "De Duinspoken", children: 8, color: "#77d5c4" },
];
function nextGroup(
  state: SimulationState,
  status: SimulationGroup["status"],
): SimulationGroup {
  const serial =
    state.groups.reduce(
      (max, item) => Math.max(max, Number(item.id.split("-").at(-1)) || 0),
      0,
    ) + 1;
  return {
    id: `exercise-group-${serial}`,
    ...groupIdeas[(serial - 1) % groupIdeas.length],
    status,
    progress: 0,
    sealed: false,
  };
}
function checkpoint(state: SimulationState, id: string): SimulationState {
  return state.completed.includes(id)
    ? state
    : { ...state, completed: [...state.completed, id] };
}
function note(state: SimulationState, text: string): SimulationState {
  const minute = Math.floor(state.clock);
  const time = `${String(Math.floor(minute / 60) % 24).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
  return {
    ...state,
    log: [
      ...state.log,
      { id: (state.log.at(-1)?.id ?? 0) + 1, text, time },
    ].slice(-30),
  };
}
function gateOccupied(state: SimulationState) {
  return state.groups.some(
    (group) => group.status === "inside" || group.status === "arrived",
  );
}
/** Release one existing queued group, in insertion order, only when the open gate is idle. */
function dispatchWaitingGroup(state: SimulationState): SimulationState {
  if (
    !state.started ||
    state.gate !== "open" ||
    gateOccupied(state) ||
    state.groups.some((group) => group.status === "approaching")
  )
    return state;
  const waiting = state.groups.find((group) => group.status === "waiting");
  if (!waiting) return state;
  const groups = state.groups.map((group) =>
    group.id === waiting.id
      ? { ...group, status: "approaching" as const, progress: 0 }
      : group,
  );
  return note(
    checkpoint({ ...state, groups }, "approaching"),
    `${waiting.name} vertrekt automatisch naar jullie oefenpoort. Jullie ontvangen één groep tegelijk.`,
  );
}
export function simulationReducer(
  state: SimulationState,
  action: SimulationAction,
): SimulationState {
  if (action.type === "RESET") return createSimulation();
  if (action.type === "MODE") return { ...state, mode: action.mode };
  if (action.type === "START")
    return state.started
      ? state
      : note(
          { ...state, started: true },
          "De fictieve oefenavond staat klaar. Jij bedient de poort.",
        );
  if (!state.started) return state;
  switch (action.type) {
    case "OPEN":
      if (state.gate === "open") return dispatchWaitingGroup(state);
      return dispatchWaitingGroup(
        note(
          checkpoint({ ...state, gate: "open", running: true }, "open"),
          "De oefenpoort is open. Oefengroepen mogen op pad.",
        ),
      );
    case "SEND_GROUP": {
      if (state.gate !== "open")
        return note(
          state,
          "Geen nieuwe oefengroep vertrokken: open of hervat eerst de poort.",
        );
      if (
        state.groups.some((group) => group.status === "approaching") ||
        gateOccupied(state)
      )
        return note(state, "Wacht tot het huidige oefenbezoek is afgerond.");
      const waiting = state.groups.find((group) => group.status === "waiting");
      const group = waiting ?? nextGroup(state, "approaching");
      const groups = waiting
        ? state.groups.map((item) =>
            item.id === group.id
              ? { ...item, status: "approaching" as const }
              : item,
          )
        : [...state.groups, group];
      return note(
        checkpoint({ ...state, groups }, "approaching"),
        `${group.name} vertrekt naar jullie oefenpoort.`,
      );
    }
    case "TICK": {
      if (!state.running) return state;
      const occupied = gateOccupied(state);
      let arrivalClaimed = occupied;
      const newlyArrived: string[] = [];
      const groups = state.groups.map((group) => {
        if (group.status !== "approaching") return group;
        const progress = Math.min(100, group.progress + 10 * state.speed);
        if (progress >= 100 && !arrivalClaimed) {
          arrivalClaimed = true;
          newlyArrived.push(group.name);
          return { ...group, progress, status: "arrived" as const };
        }
        return {
          ...group,
          progress: arrivalClaimed ? Math.min(progress, 88) : progress,
        };
      });
      const result = { ...state, groups, clock: state.clock + state.speed };
      return newlyArrived.length
        ? note(
            result,
            `${newlyArrived[0]} staat bij de oefenpoort. Bevestig hun aankomst.`,
          )
        : result;
    }
    case "CONFIRM_ARRIVAL": {
      if (state.gate === "closed") return state;
      const group = state.groups.find(
        (item) =>
          item.status === "arrived" &&
          (!action.groupId || item.id === action.groupId),
      );
      if (!group || state.groups.some((item) => item.status === "inside"))
        return state;
      const groups = state.groups.map((item) =>
        item.id === group.id ? { ...item, status: "inside" as const } : item,
      );
      return note(
        checkpoint(
          {
            ...state,
            groups,
            visits: state.visits + 1,
            children: state.children + group.children,
          },
          "arrived",
        ),
        `${group.name}: aankomst bevestigd voor ${group.children} fictieve kinderen.`,
      );
    }
    case "FINISH_VISIT": {
      const group = state.groups.find(
        (item) =>
          item.status === "inside" &&
          !item.sealed &&
          (!action.groupId || item.id === action.groupId),
      );
      if (!group) return state;
      const groups = state.groups.map((item) =>
        item.id === group.id
          ? { ...item, status: "done" as const, sealed: true }
          : item,
      );
      return dispatchWaitingGroup(
        note(
          checkpoint(
            { ...state, groups, seals: state.seals + group.children },
            "seal",
          ),
          `${group.name} loopt verder. ${group.children} oefenzegels schitteren in hun fictieve boeken.`,
        ),
      );
    }
    case "CROWD": {
      if (state.gate !== "open")
        return note(state, "Open de oefenpoort voordat je de drukte oefent.");
      let result = state;
      let added = 0;
      while (
        added < 2 &&
        result.groups.filter((group) => group.status !== "done").length < 3
      ) {
        const travelling =
          result.groups.some((group) => group.status === "approaching") ||
          gateOccupied(result);
        const group = nextGroup(result, travelling ? "waiting" : "approaching");
        result = { ...result, groups: [...result.groups, group] };
        added++;
      }
      if (!added)
        return note(
          state,
          "Er wachten al genoeg oefengroepen. Ontvang er eerst één.",
        );
      return note(
        result.groups.some((group) => group.status === "waiting")
          ? checkpoint(result, "crowd")
          : result,
        `${added} fictieve oefengroepen toegevoegd. De wachtende groep houdt afstand.`,
      );
    }
    case "PAUSE":
      if (state.gate !== "open") return state;
      return note(
        checkpoint({ ...state, gate: "paused" }, "pause"),
        "De oefenpoort is gepauzeerd. Geen nieuwe groep vertrekt; een onderweg of aanwezig bezoek mag nog worden afgerond.",
      );
    case "RESUME":
      if (state.gate !== "paused") return state;
      return dispatchWaitingGroup(
        note(
          checkpoint({ ...state, gate: "open", running: true }, "resume"),
          "De oefenpoort is hervat. Een wachtende oefengroep mag weer op pad zodra de poort vrij is.",
        ),
      );
    case "MESSAGE": {
      const text = action.text.trim().slice(0, 500);
      if (!text) return state;
      return note(
        checkpoint(
          {
            ...state,
            message: text,
            helpReply:
              "Fictieve regie · oefenantwoord: bericht ontvangen! We kijken in deze demo even met jullie mee. Dit antwoord is lokaal gemaakt.",
          },
          "message",
        ),
        "Jouw oefenbericht staat in het lokale oefengesprek. De fictieve regie heeft geantwoord.",
      );
    }
    case "HELP":
      return note(
        checkpoint(
          {
            ...state,
            message: "Kunnen jullie even meekijken bij onze oefenpoort?",
            helpReply:
              "Fictieve regie · oefenantwoord: natuurlijk! Zet de oefenpoort gerust op pauze, rond de aanwezige groep af en hervat wanneer je klaar bent. Dit is alleen een lokale demo.",
          },
          "message",
        ),
        "Lokale hulpvraag geoefend. Lees het fictieve regieantwoord.",
      );
    case "CLOSE": {
      if (
        state.groups.some((group) =>
          ["approaching", "arrived", "inside"].includes(group.status),
        )
      )
        return note(
          state,
          "Rond de onderweg of aanwezige oefengroep eerst af. Daarna kun je de oefenpoort sluiten.",
        );
      const readyToFinish = simulationSteps.every(
        (step) => step.id === "finish" || state.completed.includes(step.id),
      );
      if (state.gate === "closed") {
        if (!readyToFinish || state.completed.includes("finish")) return state;
        return note(
          checkpoint(
            {
              ...state,
              running: false,
              groups: state.groups.filter(
                (group) => group.status !== "waiting",
              ),
            },
            "finish",
          ),
          "De oefenpoort was al veilig gesloten. Alle oefenstappen zijn nu afgerond; jullie echte poort blijft ongewijzigd.",
        );
      }
      const groups = state.groups.filter((group) => group.status !== "waiting");
      let result: SimulationState = {
        ...state,
        gate: "closed",
        running: false,
        groups,
      };
      if (readyToFinish) result = checkpoint(result, "finish");
      return note(
        result,
        "De oefenpoort is gesloten. Wachtende oefengroepen zijn afgemeld. Jullie echte poort is niet gewijzigd.",
      );
    }
    case "PLAY":
      return { ...state, running: action.running };
    case "SPEED":
      return { ...state, speed: action.speed };
    case "FINALE":
      if (!state.completed.includes("seal") || state.finale) return state;
      return note(
        { ...state, finale: true },
        "Een gouden oefenfinale! Dit is een extra demo-effect, geen echte finalezegel of evenementvoltooiing.",
      );
    default:
      return state;
  }
}
