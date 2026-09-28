import { z } from "zod";

export const channels = ["website", "parents", "houses"] as const;
export type NewsChannel = (typeof channels)[number];
export const channelLabels: Record<NewsChannel, string> = {
  website: "Hoofdwebsite",
  parents: "Ouderportaal",
  houses: "Huizenportaal",
};
export const audienceLabels = {
  parents: "Ouders/verzorgers",
  primary_contacts: "Hoofdcontacten",
  leaders: "Groepsleiders",
  viewers: "Gekoppelde meekijkers",
  applicants: "Aangemelde huiseigenaren",
  portals: "Goedgekeurde poorten",
  portal_owners: "Primaire huiscontacten",
  portal_members: "Poortkamerleden",
  portal_editors: "Poortkamer met bewerkingsrechten",
  invited: "Uitgenodigde Poortkamerleden",
  organization: "Vrijwilligers/organisatie",
  subscribers: "Alle Nachtpost-abonnees",
} as const;
export const uuid = z.string().uuid();
export function safeEditorialUrl(value: string): boolean {
  if (!value || value.length > 2000 || /[\s\\\u0000-\u001f\u007f]/u.test(value))
    return false;
  if (value.startsWith("/") && !value.startsWith("//")) return true;
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      !url.username &&
      !url.password &&
      (!url.port || url.port === "443")
    );
  } catch {
    return false;
  }
}
export const ctaSchema = z
  .object({
    label: z.string().trim().min(1).max(60),
    url: z
      .string()
      .refine(
        safeEditorialUrl,
        "Gebruik een interne route of veilige HTTPS-link.",
      ),
  })
  .strict();
const markSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("bold") }).strict(),
  z.object({ type: z.literal("italic") }).strict(),
  z.object({ type: z.literal("underline") }).strict(),
  z
    .object({
      type: z.literal("link"),
      attrs: z.object({ href: z.string().refine(safeEditorialUrl) }).strict(),
    })
    .strict(),
]);
export type RichNode = {
  type: string;
  text?: string;
  attrs?: Record<string, string | number | null>;
  marks?: z.infer<typeof markSchema>[];
  content?: RichNode[];
};
const align = z.enum(["left", "center", "right"]).nullable().optional();
const richNode: z.ZodType<RichNode> = z.lazy(() =>
  z.discriminatedUnion("type", [
    z
      .object({ type: z.literal("doc"), content: z.array(richNode).max(200) })
      .strict(),
    z
      .object({
        type: z.literal("text"),
        text: z.string().min(1).max(20000),
        marks: z.array(markSchema).max(4).optional(),
      })
      .strict(),
    z
      .object({
        type: z.literal("paragraph"),
        attrs: z.object({ textAlign: align }).strict().optional(),
        content: z.array(richNode).max(500).optional(),
      })
      .strict(),
    z
      .object({
        type: z.literal("heading"),
        attrs: z
          .object({
            level: z.union([z.literal(2), z.literal(3)]),
            textAlign: align,
          })
          .strict(),
        content: z.array(richNode).max(200).optional(),
      })
      .strict(),
    z
      .object({
        type: z.enum(["bulletList", "listItem", "blockquote", "callout"]),
        content: z.array(richNode).min(1).max(100),
      })
      .strict(),
    z
      .object({
        type: z.literal("orderedList"),
        attrs: z
          .object({
            start: z.number().int().min(1).max(1000).optional(),
            type: z.null().optional(),
          })
          .strict()
          .optional(),
        content: z.array(richNode).min(1).max(100),
      })
      .strict(),
    z.object({ type: z.enum(["hardBreak", "horizontalRule"]) }).strict(),
    z
      .object({
        type: z.literal("image"),
        attrs: z
          .object({
            mediaId: uuid,
            alt: z.string().trim().min(1).max(300),
            caption: z.string().max(500),
            width: z.union([z.literal(50), z.literal(75), z.literal(100)]),
          })
          .strict(),
      })
      .strict(),
  ]),
);
export function validateRichContent(input: unknown): RichNode {
  if (JSON.stringify(input).length > 60000)
    throw new Error("De tekst is te lang.");
  const walk = (node: unknown, depth: number) => {
    if (depth > 10) throw new Error("De tekst bevat te veel geneste blokken.");
    if (
      node &&
      typeof node === "object" &&
      "content" in node &&
      Array.isArray(node.content)
    )
      node.content.forEach((child) => walk(child, depth + 1));
  };
  walk(input, 0);
  const result = richNode.parse(input);
  if (result.type !== "doc") throw new Error("Een document is verplicht.");
  return result;
}
export const documentSchema = z.unknown().transform(validateRichContent);
export const emptyDocument: RichNode = {
  type: "doc",
  content: [{ type: "paragraph" }],
};
export const articleSchema = z
  .object({
    title: z.string().trim().min(3).max(160),
    intro: z.string().trim().max(220),
    heroId: uuid.nullable(),
    heroAlt: z.string().trim().max(300),
    heroCaption: z.string().max(500),
    author: z.string().max(100),
    categoryId: uuid.nullable(),
    body: documentSchema,
    cta: ctaSchema.nullable(),
  })
  .strict()
  .refine((v) => !v.heroId || v.heroAlt.length > 0, {
    message: "Vul een alt-tekst in.",
  });
export type ArticleContent = z.infer<typeof articleSchema>;
export const blankArticle: ArticleContent = {
  title: "",
  intro: "",
  heroId: null,
  heroAlt: "",
  heroCaption: "",
  author: "",
  categoryId: null,
  body: emptyDocument,
  cta: null,
};
export type Placement = {
  channel: NewsChannel;
  listed: boolean;
  featured: boolean;
  startsAt: string;
  endsAt: string | null;
  pushAt: string | null;
  cta: z.infer<typeof ctaSchema> | null;
  state?: string;
};
export type NewsItem = {
  id: string;
  slug: string;
  versionId: string;
  version: number;
  content: ArticleContent;
  publishedAt: string;
  category: string | null;
  featured: boolean;
  read: boolean;
  cta: z.infer<typeof ctaSchema> | null;
  channel: NewsChannel;
};
export function slugify(title: string) {
  return title
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 100);
}
export function richText(node: RichNode): string {
  return (
    node.text ??
    (node.type === "image"
      ? String(node.attrs?.caption ?? "")
      : (node.content ?? [])
          .map(richText)
          .join(
            [
              "doc",
              "bulletList",
              "orderedList",
              "blockquote",
              "listItem",
            ].includes(node.type)
              ? "\n"
              : "",
          ))
  );
}
export function referencedMedia(content: ArticleContent) {
  const ids = new Set<string>(content.heroId ? [content.heroId] : []);
  const visit = (node: RichNode) => {
    if (node.type === "image") ids.add(String(node.attrs?.mediaId));
    node.content?.forEach(visit);
  };
  visit(content.body);
  return [...ids];
}
// Resolve wall time with Intl, rejecting missing/ambiguous DST hours. The UI asks
// for an unambiguous time instead of silently moving an editorial deadline.
export function amsterdamToUtc(wall: string): string {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(wall))
    throw new Error("Vul een geldige datum en tijd in.");
  const approximate = Date.parse(`${wall}Z`);
  const format = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Europe/Amsterdam",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
  const candidates = [1, 2]
    .map((offset) => new Date(approximate - offset * 3600000))
    .filter((value) => format.format(value).replace(" ", "T") === wall);
  if (candidates.length !== 1)
    throw new Error(
      "Deze tijd bestaat niet of komt tweemaal voor door de zomer-/wintertijd. Kies een andere tijd.",
    );
  return candidates[0].toISOString();
}
export function amsterdamInput(utc: string) {
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Europe/Amsterdam",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  })
    .format(new Date(utc))
    .replace(" ", "T");
}
export const audienceSchema = z
  .object({
    roles: z
      .array(
        z.enum(
          Object.keys(audienceLabels) as [
            keyof typeof audienceLabels,
            ...(keyof typeof audienceLabels)[],
          ],
        ),
      )
      .min(1)
      .max(12),
    registrationStatus: z.enum(["submitted", "draft", "cancelled"]).optional(),
    paid: z.boolean().optional(),
    assigned: z.boolean().optional(),
    startSlotId: uuid.optional(),
    startsAfter: z.string().datetime().optional(),
    startsBefore: z.string().datetime().optional(),
    portalComplete: z.boolean().optional(),
    portalApproved: z.boolean().optional(),
    portalActive: z.boolean().optional(),
    worldId: uuid.optional(),
  })
  .strict();
export type Audience = z.infer<typeof audienceSchema>;
export const campaignSchema = z
  .object({
    internalName: z.string().trim().min(3).max(120),
    subject: z
      .string()
      .trim()
      .min(3)
      .max(200)
      .refine((s) => !/[\r\n]/.test(s)),
    preheader: z.string().trim().min(1).max(180),
    eyebrow: z.string().trim().min(1).max(100),
    article: articleSchema,
    newsVersionIds: z.array(uuid).max(8),
    closing: z.string().max(2000),
    senderName: z.string().trim().min(1).max(120),
  })
  .strict();
export type CampaignContent = z.infer<typeof campaignSchema>;
