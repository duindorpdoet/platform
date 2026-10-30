import { readinessFromError } from "./start-publication-readiness";

/** Read failures must never claim a location or planning write has failed. */
export function startReadError(error: unknown, action = "Startregie ophalen") {
  const failure: { message?: unknown; name?: unknown; code?: unknown; details?: unknown } = typeof error === "string" ? { message: error } : error && typeof error === "object"
    ? error as { message?: unknown; name?: unknown; code?: unknown; details?: unknown } : {};
  const message = [failure.name, failure.message].filter(value => typeof value === "string").join(" ");
  const code = typeof failure.code === "string" && /^[A-Z0-9_]{2,80}$/.test(failure.code) ? failure.code : null;
  const reference = code ? ` (${code})` : "";
  const readiness = readinessFromError(typeof failure.details === "string" ? failure.details : null);
  if (readiness) return `${readiness.reasons.map(reason => reason.message).join(" ")}${reference}`;
  if (code === "57014" || /statement timeout/i.test(message))
    return `${action} duurt te lang. De database heeft de controle afgebroken. Probeer opnieuw.${reference}`;
  if (code === "42501" || /PGRST30[123]/.test(code ?? "") || /NOT_AUTHORIZED|JWT.*expired|invalid.*JWT/i.test(message))
    return `${action} is niet toegestaan met de huidige sessie. Log opnieuw in of controleer je toegang.${reference}`;
  if (/STALE|INPUT_CHANGED|VERSION_CONFLICT|SOURCE_CHANGED/.test(message))
    return `De planning is intussen gewijzigd. Vernieuw de gegevens en beoordeel de startafspraken opnieuw.${reference}`;
  if (/abort|fetch failed|failed to fetch|network|timeout/i.test(message))
    return `${action} is tijdelijk niet gelukt. Controleer de verbinding en probeer opnieuw.${reference}`;
  return `${action} is niet gelukt. Probeer opnieuw.${reference}`;
}
