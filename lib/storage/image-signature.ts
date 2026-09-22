export const PORTAL_IMAGE_LIMIT = 8 * 1024 * 1024;

const signatures = {
  "image/jpeg": { extension: "jpg", matches: (bytes: Uint8Array) => bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff },
  "image/png": { extension: "png", matches: (bytes: Uint8Array) => bytes.length >= 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((value, index) => bytes[index] === value) },
  "image/webp": { extension: "webp", matches: (bytes: Uint8Array) => bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP" },
} as const;

export function validatedPortalImage(bytes: Uint8Array, declaredType: string, reportedSize = bytes.byteLength) {
  if (reportedSize < 1 || reportedSize > PORTAL_IMAGE_LIMIT) return null;
  const signature = signatures[declaredType as keyof typeof signatures];
  if (!signature || !signature.matches(bytes)) return null;
  return { contentType: declaredType as keyof typeof signatures, extension: signature.extension };
}
