import "server-only";

import { contentForMessage, UnknownMailTemplateError } from "./mail-catalog";
import { InvalidMailTemplateError, renderPremiumEmail, type PremiumMailBrand } from "./premium-template";

import { validatedTikkieUrl } from "./tikkie-url";

type TemplateInput = { messageType: string; payload: Record<string, unknown> };

function configuredBrand(): PremiumMailBrand {
  const configuredSiteUrl = process.env.APP_URL || process.env.NEXT_PUBLIC_SITE_URL;
  if (!configuredSiteUrl) throw new InvalidMailTemplateError("A public mail base URL is required");

  let site: URL;
  try {
    site = new URL(configuredSiteUrl);
  } catch {
    throw new InvalidMailTemplateError("The public mail base URL is invalid");
  }
  if (site.protocol !== "https:" || site.username || site.password || site.search || site.hash) {
    throw new InvalidMailTemplateError("The public mail base URL must be a clean HTTPS URL");
  }

  const baseUrl = site.href.replace(/\/$/, "");
  const supportEmail = process.env.ORGANIZATION_SUPPORT_EMAIL || process.env.SENDGRID_REPLY_TO || "halloween@duindorpdoet.nl";
  return {
    name: "De Duindorpse Poorten van Halloween",
    supportEmail,
    homeUrl: `${baseUrl}/`,
    contactUrl: `${baseUrl}/contact`,
    privacyUrl: `${baseUrl}/privacy`,
    logoUrl: `${baseUrl}/images/logo.webp`,
    heroUrl: `${baseUrl}/images/01-home-hero-duindorp-bij-avond-960.webp`,
    allowedLinkHosts: [site.hostname],
    allowedImageHosts: [site.hostname],
  };
}

export function renderTransactionalMail({ messageType, payload }: TemplateInput) {
  const brand = configuredBrand();
  const paymentUrl = messageType === "payment_link_ready" ? validatedTikkieUrl(payload.externalUrl) : undefined;
  if (paymentUrl) brand.allowedLinkHosts.push(new URL(paymentUrl).hostname);
  return renderPremiumEmail(contentForMessage(messageType, payload, brand), brand);
}

export { InvalidMailTemplateError, UnknownMailTemplateError };
