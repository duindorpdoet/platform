import "server-only";
import sharp from "sharp";
import { ApiError } from "@/lib/http/api";
export const mediaVariants = {
  source: [4000, 4000],
  hero: [1600, 900],
  card: [760, 500],
  portal: [720, 480],
  email: [1280, 720],
  og: [1200, 630],
} as const;
export type MediaVariant = keyof typeof mediaVariants;
export async function editorialImageVariants(
  bytes: Buffer,
  mime: string,
  focalX = 50,
  focalY = 50,
) {
  if (
    bytes.length > 12 * 1024 * 1024 ||
    !["image/jpeg", "image/png", "image/webp"].includes(mime)
  )
    throw new ApiError(
      422,
      "INVALID_IMAGE",
      "Gebruik JPG, PNG of WebP van maximaal 12 MB.",
    );
  const source = sharp(bytes, {
    limitInputPixels: 60_000_000,
    animated: false,
    failOn: "warning",
  });
  const metadata = await source.metadata();
  if (
    !metadata.format ||
    `image/${metadata.format === "jpeg" ? "jpeg" : metadata.format}` !== mime ||
    !metadata.width ||
    !metadata.height ||
    metadata.width < 320 ||
    metadata.height < 180 ||
    metadata.width > 12000 ||
    metadata.height > 12000 ||
    (metadata.pages ?? 1) > 1
  )
    throw new ApiError(
      422,
      "INVALID_IMAGE",
      "Gebruik een stilstaande afbeelding van minimaal 320 × 180 pixels.",
    );
  const normalized = await source.rotate().webp({ quality: 92 }).toBuffer();
  const { width = 0, height = 0 } = await sharp(normalized).metadata();
  const variants = await Promise.all(
    Object.entries(mediaVariants).map(async ([key, [w, h]]) => {
      let pipeline = sharp(normalized);
      if (key !== "source") {
        const ratio = w / h;
        const cropW = Math.min(width, Math.floor(height * ratio));
        const cropH = Math.min(height, Math.floor(width / ratio));
        pipeline = pipeline.extract({
          left: Math.max(
            0,
            Math.min(
              width - cropW,
              Math.round((width * focalX) / 100 - cropW / 2),
            ),
          ),
          top: Math.max(
            0,
            Math.min(
              height - cropH,
              Math.round((height * focalY) / 100 - cropH / 2),
            ),
          ),
          width: cropW,
          height: cropH,
        });
      }
      return {
        name: key,
        bytes: await pipeline
          .resize(w, h, {
            fit: key === "source" ? "inside" : "cover",
            withoutEnlargement: true,
          })
          .webp({ quality: key === "source" ? 90 : 84 })
          .toBuffer(),
      };
    }),
  );
  return { width, height, variants };
}
