import { registeredPortalImpact, type PortalRoom } from "@/lib/domain/poortkamer";

/** This projection is the complete export allowlist. No account, address or child data. */
export function portalCertificateDetails(room: Pick<PortalRoom, "portal" | "eventDate" | "registeredImpact">) {
  const impact = registeredPortalImpact(room);
  const year = /^\d{4}-\d{2}-\d{2}$/.test(room.eventDate) ? room.eventDate.slice(0, 4) : null;
  return impact && year ? { portalName: room.portal.name, portalCode: room.portal.code, year, ...impact } : null;
}
export type PortalCertificateDetails = NonNullable<ReturnType<typeof portalCertificateDetails>>;

function background(signal: AbortSignal): Promise<HTMLImageElement | null> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new DOMException("Aborted", "AbortError")); return; }
    const image = new Image();
    const finish = (value: HTMLImageElement | null) => { clearTimeout(timer); signal.removeEventListener("abort", abort); image.onload = null; image.onerror = null; resolve(value); };
    const abort = () => { clearTimeout(timer); image.onload = null; image.onerror = null; image.src = ""; signal.removeEventListener("abort", abort); reject(new DOMException("Aborted", "AbortError")); };
    const timer = setTimeout(() => finish(null), 5_000);
    image.onload = () => finish(image);
    image.onerror = () => finish(null);
    signal.addEventListener("abort", abort, { once: true });
    image.src = "/images/poortkamer-v2/certificates/gate-certificate-background.webp";
  });
}

/** Prepare before a click so native file sharing keeps the browser user gesture. */
export async function preparePortalCertificate(details: PortalCertificateDetails, signal: AbortSignal): Promise<File> {
  const canvas = document.createElement("canvas");
  canvas.width = 1600; canvas.height = 1100;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("CERTIFICATE_UNAVAILABLE");
  const image = await background(signal);
  signal.throwIfAborted();
  context.fillStyle = "#102131"; context.fillRect(0, 0, 1600, 1100);
  if (image) { context.globalAlpha = .5; context.drawImage(image, 0, 0, 1600, 1100); context.globalAlpha = 1; }
  context.fillStyle = "#08111baa"; context.fillRect(0, 0, 1600, 1100);
  context.strokeStyle = "#d8b878"; context.lineWidth = 3; context.strokeRect(45, 45, 1510, 1010);
  context.textAlign = "center"; context.fillStyle = "#dfc89e"; context.font = "28px sans-serif";
  context.fillText("DE DUINDORPSE POORTEN VAN HALLOWEEN", 800, 155, 1400);
  context.fillStyle = "#fff0ce"; context.font = "76px Georgia, serif";
  context.fillText("Officiële Poort van " + details.year, 800, 290, 1400);
  context.font = "48px Georgia, serif"; context.fillText(details.portalName, 800, 400, 1380);
  context.fillStyle = "#dfc89e"; context.font = "28px sans-serif"; context.fillText(details.portalCode, 800, 465, 1350);
  context.fillStyle = "#fff0ce"; context.font = "116px Georgia, serif";
  context.fillText(String(details.registeredGroups), 490, 655, 550); context.fillText(String(details.registeredChildren), 1110, 655, 550);
  context.fillStyle = "#dfc89e"; context.font = "32px sans-serif";
  context.fillText("Geregistreerde groepen", 490, 720, 580); context.fillText("Geregistreerde kids", 1110, 720, 580);
  context.fillStyle = "#fff0ce"; context.font = "44px Georgia, serif";
  context.fillText("Dank je wel voor jullie licht in de wijk.", 800, 875, 1400);
  context.fillStyle = "#dfc89e"; context.font = "25px sans-serif";
  context.fillText("Vooraf geregistreerd · Duindorp Halloween " + details.year, 800, 970, 1400);
  const blob = await new Promise<Blob>((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new Error("CERTIFICATE_UNAVAILABLE")), "image/png"));
  signal.throwIfAborted();
  const safeCode = details.portalCode.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 60) || "poort";
  return new File([blob], `certificaat-${safeCode}-${details.year}.png`, { type: "image/png" });
}

export function downloadPortalCertificate(file: File) {
  const url = URL.createObjectURL(file);
  const link = document.createElement("a"); link.href = url; link.download = file.name;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

/** Invoke directly in onClick with the already prepared File; never automatically retry a share. */
export async function sharePortalCertificate(file: File): Promise<"shared" | "downloaded" | "cancelled"> {
  if (typeof navigator.share === "function" && navigator.canShare?.({ files: [file] })) {
    try { await navigator.share({ title: "Ons Poortcertificaat", files: [file] }); return "shared"; }
    catch (error) { if (error instanceof Error && error.name === "AbortError") return "cancelled"; throw error; }
  }
  downloadPortalCertificate(file);
  return "downloaded";
}
