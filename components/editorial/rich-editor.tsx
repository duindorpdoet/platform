"use client";
import { useState } from "react";
import { EditorContent, useEditor, useEditorState } from "@tiptap/react";
import { Node, mergeAttributes } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import TextAlign from "@tiptap/extension-text-align";
import {
  Bold,
  Italic,
  Underline,
  List,
  ListOrdered,
  AlignLeft,
  AlignCenter,
  AlignRight,
  Quote,
  Info,
  Minus,
  Link2,
  ImagePlus,
  Undo2,
  Redo2,
} from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  safeEditorialUrl,
  validateRichContent,
  type RichNode,
} from "@/lib/editorial/content";
export type EditorialMedia = {
  id: string;
  alt: string;
  caption: string;
  width: number;
  height: number;
  focalX: number;
  focalY: number;
  uses: { versionId: string; title: string; kind: string }[];
};
const Callout = Node.create({
  name: "callout",
  group: "block",
  content: "block+",
  defining: true,
  parseHTML: () => [{ tag: "aside" }],
  renderHTML: ({ HTMLAttributes }) => [
    "aside",
    mergeAttributes(HTMLAttributes, { class: "editorial-callout" }),
    0,
  ],
});
const EditorialImage = Node.create({
  name: "image",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({
    mediaId: { default: null },
    alt: { default: "" },
    caption: { default: "" },
    width: { default: 100 },
  }),
  parseHTML: () => [],
  renderHTML: ({ node }) => [
    "figure",
    {
      style: `width:${[50, 75, 100].includes(node.attrs.width) ? node.attrs.width : 100}%`,
    },
    [
      "img",
      {
        src: `/api/editorial/media/${node.attrs.mediaId}/hero`,
        alt: node.attrs.alt,
      },
    ],
    ["figcaption", {}, node.attrs.caption],
  ],
});
function normalized(node: RichNode): RichNode {
  return {
    ...node,
    ...(node.content ? { content: node.content.map(normalized) } : {}),
    ...(node.marks
      ? {
          marks: node.marks.map((m) =>
            m.type === "link"
              ? { type: "link", attrs: { href: m.attrs.href } }
              : { type: m.type },
          ),
        }
      : {}),
  };
}
export function RichEditor({
  value,
  onChange,
  media,
  disabled = false,
}: {
  value: RichNode;
  onChange: (value: RichNode) => void;
  media: EditorialMedia[];
  disabled?: boolean;
}) {
  const [dialog, setDialog] = useState<"link" | "image" | null>(null);
  const [href, setHref] = useState("");
  const [mediaId, setMediaId] = useState("");
  const [caption, setCaption] = useState("");
  const [alt, setAlt] = useState("");
  const [width, setWidth] = useState(100);
  const [error, setError] = useState("");
  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        heading: { levels: [2, 3] },
        code: false,
        codeBlock: false,
        strike: false,
        link: {
          openOnClick: false,
          autolink: false,
          linkOnPaste: false,
          isAllowedUri: (url) => safeEditorialUrl(url),
        },
      }),
      TextAlign.configure({
        types: ["heading", "paragraph"],
        alignments: ["left", "center", "right"],
      }),
      Callout,
      EditorialImage,
    ],
    content: value,
    immediatelyRender: false,
    editable: !disabled,
    editorProps: {
      attributes: {
        "aria-label": "Berichtinhoud",
        role: "textbox",
        "aria-multiline": "true",
      },
    },
    onUpdate: ({ editor: instance }) => {
      try {
        onChange(
          validateRichContent(normalized(instance.getJSON() as RichNode)),
        );
        setError("");
      } catch {
        setError(
          "Deze opmaak is niet toegestaan. Maak de laatste wijziging ongedaan.",
        );
      }
    },
  });
  const state = useEditorState({
    editor,
    selector: ({ editor: e }) =>
      e
        ? {
            bold: e.isActive("bold"),
            italic: e.isActive("italic"),
            underline: e.isActive("underline"),
            bullet: e.isActive("bulletList"),
            ordered: e.isActive("orderedList"),
            heading: e.isActive("heading", { level: 2 })
              ? "2"
              : e.isActive("heading", { level: 3 })
                ? "3"
                : "p",
          }
        : null,
  });
  if (!editor) return <p aria-busy="true">Teksteditor wordt geopend…</p>;
  const tool = (
    label: string,
    icon: React.ReactNode,
    action: () => void,
    active?: boolean,
  ) => (
    <button
      key={label}
      type="button"
      title={label}
      aria-label={label}
      aria-pressed={active}
      disabled={disabled}
      onClick={action}
    >
      {icon}
    </button>
  );
  return (
    <>
      <div className="editorial-editor">
        <div
          className="editorial-format-bar"
          role="toolbar"
          aria-label="Tekstopmaak"
        >
          <select
            aria-label="Tekststijl"
            disabled={disabled}
            value={state?.heading ?? "p"}
            onChange={(e) =>
              e.target.value === "p"
                ? editor.chain().focus().setParagraph().run()
                : editor
                    .chain()
                    .focus()
                    .toggleHeading({ level: Number(e.target.value) as 2 | 3 })
                    .run()
            }
          >
            <option value="p">Alinea</option>
            <option value="2">Kop 2</option>
            <option value="3">Kop 3</option>
          </select>
          {tool(
            "Vet",
            <Bold size={16} />,
            () => editor.chain().focus().toggleBold().run(),
            state?.bold,
          )}
          {tool(
            "Cursief",
            <Italic size={16} />,
            () => editor.chain().focus().toggleItalic().run(),
            state?.italic,
          )}
          {tool(
            "Onderstrepen",
            <Underline size={16} />,
            () => editor.chain().focus().toggleUnderline().run(),
            state?.underline,
          )}
          {tool(
            "Opsomming",
            <List size={17} />,
            () => editor.chain().focus().toggleBulletList().run(),
            state?.bullet,
          )}
          {tool(
            "Genummerde lijst",
            <ListOrdered size={17} />,
            () => editor.chain().focus().toggleOrderedList().run(),
            state?.ordered,
          )}
          {tool("Links uitlijnen", <AlignLeft size={17} />, () =>
            editor.chain().focus().setTextAlign("left").run(),
          )}
          {tool("Centreren", <AlignCenter size={17} />, () =>
            editor.chain().focus().setTextAlign("center").run(),
          )}
          {tool("Rechts uitlijnen", <AlignRight size={17} />, () =>
            editor.chain().focus().setTextAlign("right").run(),
          )}
          {tool("Quote", <Quote size={17} />, () =>
            editor.chain().focus().toggleBlockquote().run(),
          )}
          {tool("Informatiekader", <Info size={17} />, () =>
            editor.chain().focus().toggleWrap("callout").run(),
          )}
          {tool("Scheidingslijn", <Minus size={17} />, () =>
            editor.chain().focus().setHorizontalRule().run(),
          )}
          {tool("Link instellen", <Link2 size={17} />, () => {
            setHref(editor.getAttributes("link").href ?? "");
            setDialog("link");
          })}
          {tool(
            "Afbeelding invoegen of aanpassen",
            <ImagePlus size={17} />,
            () => {
              const attrs = editor.getAttributes("image");
              setMediaId(attrs.mediaId ?? "");
              setAlt(attrs.alt ?? "");
              setCaption(attrs.caption ?? "");
              setWidth(attrs.width ?? 100);
              setDialog("image");
            },
          )}
          {tool("Ongedaan maken", <Undo2 size={17} />, () =>
            editor.chain().focus().undo().run(),
          )}
          {tool("Opnieuw", <Redo2 size={17} />, () =>
            editor.chain().focus().redo().run(),
          )}
        </div>
        <EditorContent editor={editor} />
      </div>
      {error && (
        <p role="alert" className="editorial-notice error">
          {error}
        </p>
      )}
      <Dialog
        open={dialog !== null}
        onOpenChange={(open) => !open && setDialog(null)}
      >
        <DialogContent className="editorial-dialog">
          <DialogTitle>
            {dialog === "link" ? "Link instellen" : "Afbeeldingsblok"}
          </DialogTitle>
          <DialogDescription>
            {dialog === "link"
              ? "Gebruik een interne route of een volledige HTTPS-link."
              : "Kies een afbeelding uit de mediatheek. Alt-tekst beschrijft wat er te zien is."}
          </DialogDescription>
          {dialog === "link" ? (
            <>
              <label>
                Link
                <input
                  value={href}
                  onChange={(e) => setHref(e.target.value)}
                  placeholder="/nieuws of https://…"
                />
              </label>
              <div className="editorial-actions">
                <button
                  className="btn"
                  type="button"
                  disabled={!safeEditorialUrl(href)}
                  onClick={() => {
                    editor
                      .chain()
                      .focus()
                      .extendMarkRange("link")
                      .setLink({ href })
                      .run();
                    setDialog(null);
                  }}
                >
                  Link bewaren
                </button>
                <button
                  type="button"
                  className="btn outline"
                  onClick={() => {
                    editor.chain().focus().unsetLink().run();
                    setDialog(null);
                  }}
                >
                  Link verwijderen
                </button>
              </div>
            </>
          ) : (
            <>
              <label>
                Afbeelding
                <select
                  value={mediaId}
                  onChange={(e) => {
                    const m = media.find((i) => i.id === e.target.value);
                    setMediaId(e.target.value);
                    setAlt(m?.alt ?? "");
                    setCaption(m?.caption ?? "");
                  }}
                >
                  <option value="">Kies uit de mediatheek</option>
                  {media.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.alt}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Alt-tekst
                <input
                  value={alt}
                  onChange={(e) => setAlt(e.target.value)}
                  maxLength={300}
                />
              </label>
              <label>
                Bijschrift
                <input
                  value={caption}
                  onChange={(e) => setCaption(e.target.value)}
                  maxLength={500}
                />
              </label>
              <label>
                Breedte
                <select
                  value={width}
                  onChange={(e) => setWidth(Number(e.target.value))}
                >
                  <option value={50}>50%</option>
                  <option value={75}>75%</option>
                  <option value={100}>100%</option>
                </select>
              </label>
              <button
                type="button"
                className="btn"
                disabled={!mediaId || !alt.trim()}
                onClick={() => {
                  const attrs = { mediaId, alt, caption, width };
                  if (editor.isActive("image"))
                    editor
                      .chain()
                      .focus()
                      .updateAttributes("image", attrs)
                      .run();
                  else
                    editor
                      .chain()
                      .focus()
                      .insertContent({ type: "image", attrs })
                      .run();
                  setDialog(null);
                }}
              >
                Afbeelding bewaren
              </button>
            </>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
