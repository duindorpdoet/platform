const labels: Record<string, string> = {
  "quest:riddle-1": "Het kroongeheim", "quest:riddle-2": "Het Duinlicht", "quest:riddle-3": "De Kraaienbode",
  "quest:game-1": "Symbolenvolgorde", "quest:game-2": "Lantaarnkleuren", "quest:game-3": "Kraaienparen",
};

export function awardLabel(key: string) {
  if (labels[key]) return labels[key];
  if (key === "beacon" || key === "beacon:complete") return "Duinlicht teruggegeven";
  if (key.startsWith("visit:")) return "Bezoekzegel";
  return key.startsWith("quest:") ? "Pleinmissie" : "Nachtzegel";
}
