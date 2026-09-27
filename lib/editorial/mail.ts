import "server-only";
import { serverEnv } from "@/lib/config/server-env";
import { renderPremiumEmail } from "@/lib/mail/premium-template";
import { configuredBrand } from "@/lib/mail/templates";
import {
  articleSchema,
  campaignSchema,
  referencedMedia,
  type ArticleContent,
  type CampaignContent,
  type RichNode,
} from "./content";
import { editorialToken } from "./security";
export type NewsCard = {
  versionId: string;
  slug: string;
  content: ArticleContent;
  channels: string[];
};
export type NewsletterMaterial = {
  content: CampaignContent & { newsCards: NewsCard[] };
  recipientId: string | null;
  eventId: string;
  versionId: string;
  test: boolean;
};
export function renderNewsletter(
  material: NewsletterMaterial,
  preview = false,
) {
  const { newsCards = [], ...raw } = material.content;
  const content = campaignSchema.parse(raw);
  const brand = configuredBrand();
  const secret = serverEnv().EDITORIAL_TOKEN_SECRET;
  if (!secret && !preview) throw new Error("EDITORIAL_TOKEN_NOT_CONFIGURED");
  const mediaUrls: Record<string, string> = {};
  const imageUrl = (id: string) => {
    const url = new URL(`/api/editorial/media/${id}/email`, brand.homeUrl);
    if (!preview)
      url.searchParams.set(
        "mail",
        editorialToken(secret!, "mail-media", `${material.versionId}:${id}`),
      );
    mediaUrls[id] = url.href;
    return url.href;
  };
  referencedMedia(content.article).forEach(imageUrl);
  const body: RichNode = {
    type: "doc",
    content: [...(content.article.body.content ?? [])],
  };
  for (const card of newsCards) {
    const article = articleSchema.parse(card.content);
    referencedMedia(article).forEach(imageUrl);
    const href = card.channels.includes("website")
      ? `/nieuws/${card.slug}`
      : `/omgeving/nieuws/${card.slug}`;
    body.content!.push({ type: "horizontalRule" });
    if (article.heroId)
      body.content!.push({
        type: "image",
        attrs: {
          mediaId: article.heroId,
          alt: article.heroAlt,
          caption: article.heroCaption,
          width: 100,
        },
      });
    body.content!.push(
      {
        type: "heading",
        attrs: { level: 2 },
        content: [{ type: "text", text: article.title }],
      },
      {
        type: "paragraph",
        content: [{ type: "text", text: article.intro || article.title }],
      },
      {
        type: "paragraph",
        content: [
          {
            type: "text",
            text: "Lees het nieuwsbericht",
            marks: [{ type: "link", attrs: { href } }],
          },
        ],
      },
    );
  }
  const unsubscribe = new URL("/nachtpost/afmelden", brand.homeUrl);
  if (material.recipientId && secret && !preview)
    unsubscribe.searchParams.set(
      "token",
      editorialToken(secret, "unsubscribe", material.recipientId),
    );
  const preferencesUrl = new URL("/omgeving/communicatie", brand.homeUrl).href;
  if (content.article.heroId) brand.heroUrl = imageUrl(content.article.heroId);
  const cta = content.article.cta
    ? {
        label: content.article.cta.label,
        url: new URL(content.article.cta.url, brand.homeUrl).href,
      }
    : undefined;
  if (cta)
    brand.allowedLinkHosts = [
      ...brand.allowedLinkHosts,
      new URL(cta.url).hostname,
    ];
  const rendered = renderPremiumEmail(
    {
      kind: "generic",
      subject: content.subject,
      preheader: content.preheader,
      eyebrow: content.eyebrow,
      title: content.article.title,
      paragraphs: [
        content.article.intro ||
          "Nieuws van De Duindorpse Poorten van Halloween.",
      ],
      hero: !!content.article.heroId,
      heroAlt: content.article.heroAlt,
      primaryAction: cta,
      footerReason:
        material.test || preview
          ? "Dit is een persoonlijk voorbeeld van Nachtpost. Er is geen deelnemerslijst aangeschreven."
          : "Je ontvangt Nachtpost omdat je toestemming gaf voor redactioneel nieuws. Deelname-informatie blijft beschikbaar wanneer je je afmeldt.",
      editorial: {
        body,
        mediaUrls,
        closing: content.closing,
        unsubscribeUrl: unsubscribe.href,
        preferencesUrl,
      },
    },
    brand,
  );
  const oneClick = new URL("/api/editorial/unsubscribe", brand.homeUrl);
  if (material.recipientId && secret)
    oneClick.searchParams.set(
      "token",
      editorialToken(secret, "unsubscribe", material.recipientId),
    );
  return {
    ...rendered,
    senderName: content.senderName,
    unsubscribeUrl: material.recipientId ? oneClick.href : undefined,
  };
}
