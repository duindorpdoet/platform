import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import QRCode from "qrcode";
import sharp from "sharp";
import {
  privacySafeSerialized,
  shareFormats,
  type ShareDynamic,
  type ShareFormat,
  type ShareStyle,
  type ShareTextConfig,
} from "./catalog";

export type RenderShareCardInput = {
  format: ShareFormat;
  style: ShareStyle;
  portraitAsset: string;
  landscapeAsset: string;
  textConfig: ShareTextConfig;
  dynamic: ShareDynamic;
  publicUrl: string;
  allowedOrigin: string;
  includeQr?: boolean;
  environmentLabel?: string;
};

const palette: Record<string, string> = {
  amber: "#e7a969",
  cyan: "#6fd5e7",
  violet: "#a98be9",
  emerald: "#71d09b",
  crimson: "#e17070",
  moonlight: "#d8e4eb",
};

function escapeXml(value: string) {
  return value.replace(/[<>&"']/g, (character) => ({
    "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;",
  })[character] ?? character);
}
function safePublicUrl(value: string, allowedOrigin: string) {
  const url = new URL(value);
  const approved = new URL(allowedOrigin);
  const localDevelopment = ["localhost", "127.0.0.1", "::1"].includes(url.hostname);
  if (url.protocol !== "https:" && !localDevelopment) throw new Error("UNSAFE_PUBLIC_URL");
  if (url.username || url.password || url.hash || url.origin !== approved.origin) throw new Error("UNSAFE_PUBLIC_URL");
  return url.href;
}

function resolveAsset(asset: string) {
  if (!/^\/images\/social-share\/[A-Za-z0-9_./-]+\.webp$/.test(asset) || asset.includes("..")) {
    throw new Error("UNSAFE_TEMPLATE_ASSET");
  }
  const publicRoot = path.join(process.cwd(), "public");
  const resolved = path.join(publicRoot, asset);
  if (!resolved.startsWith(`${publicRoot}${path.sep}`)) throw new Error("UNSAFE_TEMPLATE_ASSET");
  return resolved;
}

function wrap(value: string, maxCharacters: number, maxLines: number) {
  const words = value.trim().split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  for (const word of words) {
    const current = lines.at(-1);
    if (!current || `${current} ${word}`.length > maxCharacters) lines.push(word);
    else lines[lines.length - 1] = `${current} ${word}`;
  }
  if (lines.length > maxLines) {
    const visible = lines.slice(0, maxLines);
    visible[maxLines - 1] = `${visible[maxLines - 1].slice(0, Math.max(1, maxCharacters - 1)).trim()}…`;
    return visible;
  }
  return lines;
}

function dynamicLines(dynamic: ShareDynamic) {
  const values: string[] = [];
  if (dynamic.teamName) values.push(dynamic.teamName);
  if (dynamic.portalName) values.push(dynamic.portalName);
  if (dynamic.worldName) values.push(dynamic.worldName);
  if (typeof dynamic.visitedCount === "number") values.push(`${dynamic.visitedCount} zegels verzameld`);
  if (typeof dynamic.receivedGroups === "number") values.push(`${dynamic.receivedGroups} groepen ontvangen`);
  if (typeof dynamic.estimatedVisitors === "number") values.push(`circa ${dynamic.estimatedVisitors} bezoekers`);
  return values.slice(0, 3);
}

function bannerSvg(dynamic: ShareDynamic, x: number, y: number, scale: number) {
  if (!dynamic.banner || !dynamic.teamName) return "";
  const primary = palette[String(dynamic.banner.color)] ?? palette.amber;
  const secondary = palette[String(dynamic.banner.secondaryColor)] ?? palette.violet;
  return `<g transform="translate(${x} ${y}) scale(${scale})" filter="url(#softShadow)">
    <path d="M0 0h190v170l-95 62L0 170z" fill="${primary}" stroke="#f7e8cf" stroke-width="8"/>
    <path d="M95 0h95v170l-95 62z" fill="${secondary}" opacity=".9"/>
    <circle cx="95" cy="92" r="38" fill="#07111d" opacity=".76"/>
    <path d="M95 56l12 25 28 4-20 20 5 28-25-13-25 13 5-28-20-20 28-4z" fill="#f8ead4"/>
  </g>`;
}

export async function renderShareCard(input: RenderShareCardInput) {
  if (!privacySafeSerialized(input.dynamic)) throw new Error("UNSAFE_SHARE_PAYLOAD");
  const publicUrl = safePublicUrl(input.publicUrl, input.allowedOrigin);
  const size = shareFormats[input.format];
  const isPortrait = size.height > size.width;
  const source = size.source === "portrait" ? input.portraitAsset : input.landscapeAsset;
  const [background, logo, serif, sans] = await Promise.all([
    readFile(resolveAsset(source)),
    readFile(path.join(process.cwd(), "public/images/logo.webp")),
    readFile(path.join(process.cwd(), "public/fonts/deelstudio-serif-bold.ttf")),
    readFile(path.join(process.cwd(), "public/fonts/deelstudio-sans-bold.ttf")),
  ]);
  const accent = input.style === "world" ? palette[input.dynamic.worldColor ?? ""] ?? palette.amber : palette.amber;
  const left = Math.round(size.width * (isPortrait ? 0.085 : 0.075));
  const maxWidth = Math.round(size.width * (isPortrait ? 0.83 : 0.62));
  const title = (input.textConfig.title ?? "DE DUINDORPSE POORTEN").replace(
    "{{nights_remaining}}",
    String(input.dynamic.nightsRemaining ?? 0),
  );
  const titleSize = Math.round(size.width * (isPortrait ? (title.length > 29 ? 0.068 : 0.088) : (title.length > 29 ? 0.05 : 0.061)));
  const titleLines = wrap(title, isPortrait ? (title.length > 29 ? 17 : 22) : 20, 3);
  const lineHeight = Math.round(titleSize * 0.93);
  const eyebrowY = Math.round(size.height * (isPortrait ? 0.47 : 0.37));
  const titleY = eyebrowY + Math.round(size.height * (isPortrait ? 0.045 : 0.09));
  const detailsY = titleY + titleLines.length * lineHeight + Math.round(size.height * 0.025);
  const details = dynamicLines(input.dynamic);
  const small = Math.round(size.width * (isPortrait ? 0.034 : 0.023));
  const svg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${size.width}" height="${size.height}">
    <defs>
      <style>@font-face{font-family:ShareSerif;src:url(data:font/ttf;base64,${serif.toString("base64")})} @font-face{font-family:ShareSans;src:url(data:font/ttf;base64,${sans.toString("base64")})}</style>
      <linearGradient id="scrim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#02060a" stop-opacity=".1"/><stop offset=".38" stop-color="#03101a" stop-opacity=".25"/><stop offset="1" stop-color="#03070c" stop-opacity=".94"/></linearGradient>
      <radialGradient id="glow"><stop stop-color="${accent}" stop-opacity=".3"/><stop offset="1" stop-color="${accent}" stop-opacity="0"/></radialGradient>
      <filter id="softShadow"><feDropShadow dx="0" dy="9" stdDeviation="12" flood-opacity=".5"/></filter>
    </defs>
    <rect width="100%" height="100%" fill="url(#scrim)"/><ellipse cx="${size.width * .82}" cy="${size.height * .54}" rx="${size.width * .45}" ry="${size.height * .35}" fill="url(#glow)"/>
    <line x1="${left}" x2="${left + Math.round(maxWidth * .28)}" y1="${eyebrowY - 26}" y2="${eyebrowY - 26}" stroke="${accent}" stroke-width="4"/>
    <text x="${left}" y="${eyebrowY}" fill="#f0c499" font-family="ShareSans" font-size="${small * .68}" font-weight="700" letter-spacing="4">${escapeXml(input.textConfig.eyebrow ?? "DEEL DE MAGIE")}</text>
    ${titleLines.map((line, index) => `<text x="${left}" y="${titleY + index * lineHeight}" fill="#fffaf1" font-family="ShareSerif" font-size="${titleSize}" font-weight="700">${escapeXml(line)}</text>`).join("")}
    ${(input.textConfig.subtitle ? wrap(input.textConfig.subtitle, isPortrait ? 35 : 55, 2) : []).map((line, index) => `<text x="${left}" y="${detailsY + index * small * 1.25}" fill="#f3d8bf" font-family="ShareSans" font-size="${small}" font-weight="700" letter-spacing="1">${escapeXml(line)}</text>`).join("")}
    ${details.map((line, index) => `<text x="${left}" y="${detailsY + (input.textConfig.subtitle ? small * 3 : 0) + index * small * 1.35}" fill="#f4eee5" font-family="ShareSans" font-size="${small}" font-weight="700">${escapeXml(line)}</text>`).join("")}
    <text x="${left}" y="${Math.round(size.height * .88)}" fill="#f4eee5" font-family="ShareSans" font-size="${small}" font-weight="700">${escapeXml(input.textConfig.date ?? "31 OKTOBER 2026")}</text>
    <text x="${left}" y="${Math.round(size.height * .925)}" fill="#bfd0da" font-family="ShareSans" font-size="${Math.round(small * .72)}">duindorpdoet.nl</text>
    ${input.environmentLabel ? `<text x="${size.width / 2}" y="${size.height / 2}" text-anchor="middle" fill="#ffffff" fill-opacity=".22" font-family="ShareSans" font-size="${Math.round(size.width * .11)}" font-weight="700" transform="rotate(-20 ${size.width / 2} ${size.height / 2})">${escapeXml(input.environmentLabel)}</text>` : ""}
    ${bannerSvg(input.dynamic, Math.round(size.width * (isPortrait ? .69 : .78)), Math.round(size.height * (isPortrait ? .70 : .56)), isPortrait ? .9 : .65)}
  </svg>`);
  const logoWidth = Math.round(size.width * (isPortrait ? .39 : .24));
  const composites: Array<{ input: Buffer; top: number; left: number }> = [
    { input: svg, top: 0, left: 0 },
    { input: await sharp(logo).resize({ width: logoWidth, withoutEnlargement: true }).png().toBuffer(), top: Math.round(size.height * .055), left },
  ];
  if (input.includeQr) {
    const qrSize = Math.round(size.width * (isPortrait ? .15 : .105));
    const qr = await QRCode.toBuffer(publicUrl, { type: "png", width: qrSize, margin: 2, color: { dark: "#06101aff", light: "#fffaf1ff" } });
    composites.push({ input: qr, top: size.height - left - qrSize, left: size.width - left - qrSize });
  }
  return sharp(background)
    .resize(size.width, size.height, { fit: "cover", position: "centre" })
    .composite(composites)
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
}
