/** Spreadsheet-safe field, including leading whitespace/control characters. */
export function csvField(value: unknown) {
  const text = typeof value === "object" && value !== null ? JSON.stringify(value) : String(value ?? "");
  const unsafe = /^[\s\uFEFF]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text);
  return `"${unsafe ? "'" : ""}${text.replaceAll('"', '""')}"`;
}
