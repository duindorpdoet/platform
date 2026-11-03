import { apiFailure, correlationId } from "@/lib/http/api";
import { frightnightSnapshot } from "@/lib/frightnight/server";
import { passDocument } from "@/lib/frightnight/downloads";
import sharp from "sharp";
import { join } from "node:path";
let logo: Promise<string> | undefined;
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    logo ??= sharp(join(process.cwd(), "public/frightnight/logo.png")).resize({ width: 360, withoutEnlargement: true }).png().toBuffer().then(buffer => `data:image/png;base64,${buffer.toString("base64")}`);
    return new Response(passDocument(snapshot, await logo), { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store", "Content-Disposition": 'attachment; filename="FrightNight-2027-Nachtpas.html"', "X-Content-Type-Options": "nosniff" } });
  }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
