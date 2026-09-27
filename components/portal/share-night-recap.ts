import type { PortalRoom } from "@/lib/domain/poortkamer";

/** User-triggered export. Deliberately excludes names, addresses, team and chat. */
export async function shareNightRecap(room: PortalRoom) {
  const canvas = document.createElement("canvas");
  canvas.width = 1200;
  canvas.height = 1200;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("CARD_UNAVAILABLE");
  const backdrop = ctx.createLinearGradient(0, 0, 1200, 1200);
  backdrop.addColorStop(0, "#1b3241");
  backdrop.addColorStop(0.65, "#081321");
  backdrop.addColorStop(1, "#3b2630");
  ctx.fillStyle = backdrop;
  ctx.fillRect(0, 0, 1200, 1200);
  ctx.strokeStyle = "#b88750";
  ctx.lineWidth = 2;
  ctx.strokeRect(44, 44, 1112, 1112);
  ctx.textAlign = "center";
  ctx.fillStyle = "#efc28e";
  ctx.font = "26px sans-serif";
  ctx.fillText("DE DUINDORPSE POORTEN VAN HALLOWEEN", 600, 155);
  ctx.fillStyle = "#f4ead8";
  ctx.font = "84px Georgia, serif";
  ctx.fillText("Ons Nachtverslag", 600, 295);
  ctx.font = "34px sans-serif";
  ctx.fillStyle = "#b9d2d7";
  ctx.fillText(room.portal.code, 600, 370);
  ctx.font = "150px Georgia, serif";
  ctx.fillStyle = "#efc28e";
  ctx.fillText(String(room.visits.recap.groups), 360, 625);
  ctx.fillText(String(room.visits.recap.children), 840, 625);
  ctx.font = "30px sans-serif";
  ctx.fillStyle = "#f4ead8";
  ctx.fillText("groepen ontvangen", 360, 685);
  ctx.fillText("kinderen ontvangen", 840, 685);
  ctx.font = "42px Georgia, serif";
  ctx.fillText("Samen brachten we licht in de wijk.", 600, 865);
  ctx.font = "30px sans-serif";
  ctx.fillStyle = "#b9d2d7";
  ctx.fillText("Dank je wel, Poortwachters!", 600, 935);
  ctx.font = "24px sans-serif";
  ctx.fillText(
    "De Poortkamer · 31 oktober " + room.eventDate.slice(0, 4),
    600,
    1060,
  );
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob(
      (value) =>
        value ? resolve(value) : reject(new Error("CARD_UNAVAILABLE")),
      "image/png",
    ),
  );
  const file = new File([blob], `nachtverslag-${room.portal.code}.png`, {
    type: "image/png",
  });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ title: "Ons Nachtverslag", files: [file] });
    } catch (error) {
      if (!(error instanceof Error && error.name === "AbortError")) throw error;
    }
    return;
  }
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = file.name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
