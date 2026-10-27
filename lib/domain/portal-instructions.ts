export function portalInstructionStatusLabel(status: string | null | undefined, hasEmail = true) {
  const labels: Record<string, string> = {
    pending: "In wachtrij", processing: "Wordt verwerkt", accepted: "Provider geaccepteerd",
    delivered: "Afgeleverd", failed: "Mislukt", expired: "Verlopen", suppressed: "Onderdrukt",
    deferred: "Uitgesteld", unknown: "Verzending niet bevestigd",
  };
  return labels[status ?? ""] ?? (status ? "Verzendstatus niet bekend" : hasEmail ? "Nog geen instructiemail" : "Geen instructiemail mogelijk zonder e-mailadres");
}
