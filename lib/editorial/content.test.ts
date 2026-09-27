import { describe, expect, it } from "vitest";
import {
  amsterdamToUtc,
  articleSchema,
  blankArticle,
  referencedMedia,
  safeEditorialUrl,
  slugify,
  validateRichContent,
} from "./content";
import {
  editorialRecipientAllowed,
  editorialToken,
  safeNewsDeepLink,
  verifyEditorialToken,
} from "./security";
const media = "e97d27ed-e67a-46c3-b244-928671746a20";
describe("editorial structured content", () => {
  it("accepts only the compact editor schema and safe links", () => {
    const doc = {
      type: "doc",
      content: [
        {
          type: "heading",
          attrs: { level: 2, textAlign: "center" },
          content: [
            {
              type: "text",
              text: "Een nacht",
              marks: [
                { type: "bold" },
                { type: "link", attrs: { href: "/nieuws" } },
              ],
            },
          ],
        },
        {
          type: "image",
          attrs: {
            mediaId: media,
            alt: "Verlichte poort",
            caption: "Onze wijk",
            width: 75,
          },
        },
      ],
    };
    expect(validateRichContent(doc)).toEqual(doc);
    expect(
      referencedMedia({
        ...blankArticle,
        heroId: media,
        body: validateRichContent(doc),
      }),
    ).toEqual([media]);
    for (const node of [
      { type: "html", html: "<script>run()</script>" },
      { type: "paragraph", attrs: { style: "color:red" } },
      { type: "heading", attrs: { level: 1 } },
      {
        type: "text",
        text: "x",
        marks: [{ type: "link", attrs: { href: "javascript:alert(1)" } }],
      },
    ])
      expect(() =>
        validateRichContent({ type: "doc", content: [node] }),
      ).toThrow();
  });
  it("bounds nesting and requires hero alt", () => {
    let node: unknown = { type: "paragraph" };
    for (let i = 0; i < 12; i++) node = { type: "blockquote", content: [node] };
    expect(() =>
      validateRichContent({ type: "doc", content: [node] }),
    ).toThrow();
    expect(
      articleSchema.safeParse({
        ...blankArticle,
        title: "Nachtpost",
        heroId: media,
      }).success,
    ).toBe(false);
  });
  it.each([
    "javascript:alert(1)",
    "//evil.example",
    "/\\evil.example",
    "https://name:secret@example.nl",
    "data:text/html,x",
    "https://example.nl:8080",
    "https://example.nl/\n",
  ])("rejects %s", (value) => expect(safeEditorialUrl(value)).toBe(false));
  it("normalizes a stable editable slug", () =>
    expect(slugify("De poort — één nacht!")).toBe("de-poort-een-nacht"));
});
describe("Amsterdam scheduling", () => {
  it("uses the actual seasonal offset", () => {
    expect(amsterdamToUtc("2026-10-31T18:30")).toBe("2026-10-31T17:30:00.000Z");
    expect(amsterdamToUtc("2026-09-27T18:30")).toBe("2026-09-27T16:30:00.000Z");
  });
  it.each(["2026-03-29T02:30", "2026-10-25T02:30", "2026-02-31T10:00"])(
    "rejects missing, repeated or invalid wall time %s",
    (value) => expect(() => amsterdamToUtc(value)).toThrow(),
  );
});
describe("editorial privacy and staging", () => {
  const secret = "a".repeat(48);
  it("authenticates tokens and separates purposes without email claims", () => {
    const token = editorialToken(secret, "unsubscribe", media);
    expect(verifyEditorialToken(secret, "unsubscribe", token)).toBe(media);
    expect(verifyEditorialToken(secret, "mail-media", token)).toBeNull();
    expect(verifyEditorialToken(secret, "unsubscribe", token + "x")).toBeNull();
    expect(verifyEditorialToken(secret, "unsubscribe", token + "!")).toBeNull();
    expect(
      verifyEditorialToken("b".repeat(48), "unsubscribe", token),
    ).toBeNull();
  });
  it("fails closed outside production even with live mail mode", () => {
    expect(
      editorialRecipientAllowed("staging", "parent@example.nl", new Set()),
    ).toBe(false);
    expect(
      editorialRecipientAllowed(
        "staging",
        " TEST@example.nl ",
        new Set(["test@example.nl"]),
      ),
    ).toBe(true);
  });
  it("allows only exact news routes for notification clicks", () => {
    expect(safeNewsDeepLink("/omgeving/nieuws/de-nacht")).toBe(
      "/omgeving/nieuws/de-nacht",
    );
    expect(
      safeNewsDeepLink("https://evil.example/omgeving/nieuws/de-nacht"),
    ).toBe("/omgeving");
    expect(safeNewsDeepLink("/omgeving/nieuws/../../admin")).toBe("/omgeving");
  });
});
