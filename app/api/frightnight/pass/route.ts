import { apiFailure, correlationId } from "@/lib/http/api";
import { frightnightSnapshot } from "@/lib/frightnight/server";
import { passDocument, passSvg } from "@/lib/frightnight/downloads";
import sharp from "sharp";
import { join } from "node:path";
let logo: Promise<string> | undefined;
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    logo ??= sharp(join(process.cwd(), "public/frightnight/logo.png")).resize({ width: 360, withoutEnlargement: true }).png().toBuffer().then(buffer => `data:image/png;base64,${buffer.toString("base64")}`);
    const html = new URL(request.url).searchParams.get("format") === "html";
    return new Response(html ? passDocument(snapshot, await logo) : passSvg(snapshot, await logo), { headers: { "Content-Type": html ? "text/html; charset=utf-8" : "image/svg+xml; charset=utf-8", "Cache-Control": "private, no-store", "Content-Disposition": `attachment; filename="FrightNight-2027-Nachtpas.${html ? "html" : "svg"}"`, "Content-Security-Policy": "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox", "X-Content-Type-Options": "nosniff" } });
  }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
