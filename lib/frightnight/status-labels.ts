export function paymentStatusLabel(status?: string) {
  return ({ unpaid: "Nog niet betaald", open: "Betaling staat open", pending: "Wordt verwerkt", authorized: "Wordt verwerkt", paid: "Betaald", failed: "Mislukt", cancelled: "Geannuleerd", canceled: "Geannuleerd", expired: "Verlopen", refunded: "Terugbetaald" } as Record<string, string>)[status ?? ""] ?? "Nog niet bevestigd";
}

export function journeyStatusLabel(status?: string) {
  return ({ ready: "Nog niet gestart", walking: "Onderweg", waiting: "Even wachten", paused: "Gepauzeerd", finished: "Afgerond", completed: "Afgerond", merged: "Samen op pad", archived: "Gearchiveerd" } as Record<string, string>)[status ?? ""] ?? "Nog niet gestart";
}
