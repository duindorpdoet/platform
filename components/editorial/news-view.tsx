import Link from "next/link";
import type { ReactNode } from "react";
import {
  validateRichContent,
  type RichNode,
  type NewsItem,
} from "@/lib/editorial/content";
import "./editorial.css";
export function MediaImage({
  id,
  variant = "hero",
  alt,
  className,
}: {
  id: string;
  variant?: string;
  alt: string;
  className?: string;
}) {
  return (
    <img
      className={className}
      src={`/api/editorial/media/${id}/${variant}`}
      alt={alt}
      loading="lazy"
    />
  );
}
export function RichContent({ content }: { content: RichNode }) {
  const doc = validateRichContent(content);
  const render = (node: RichNode, index: number): ReactNode => {
    const children = node.content?.map(render);
    const align = node.attrs?.textAlign as
      | "left"
      | "center"
      | "right"
      | undefined;
    switch (node.type) {
      case "doc":
        return (
          <div className="editorial-prose" key={index}>
            {children}
          </div>
        );
      case "text":
        return (node.marks ?? []).reduce<ReactNode>(
          (text, mark) =>
            mark.type === "bold" ? (
              <strong key={index}>{text}</strong>
            ) : mark.type === "italic" ? (
              <em key={index}>{text}</em>
            ) : mark.type === "underline" ? (
              <u key={index}>{text}</u>
            ) : (
              <a key={index} href={mark.attrs.href} rel="noopener noreferrer">
                {text}
              </a>
            ),
          node.text,
        );
      case "paragraph":
        return (
          <p key={index} style={{ textAlign: align }}>
            {children || <br />}
          </p>
        );
      case "heading":
        return node.attrs?.level === 2 ? (
          <h2 key={index} style={{ textAlign: align }}>
            {children}
          </h2>
        ) : (
          <h3 key={index} style={{ textAlign: align }}>
            {children}
          </h3>
        );
      case "bulletList":
        return <ul key={index}>{children}</ul>;
      case "orderedList":
        return (
          <ol key={index} start={Number(node.attrs?.start ?? 1)}>
            {children}
          </ol>
        );
      case "listItem":
        return <li key={index}>{children}</li>;
      case "blockquote":
        return <blockquote key={index}>{children}</blockquote>;
      case "callout":
        return (
          <aside key={index} className="editorial-callout">
            {children}
          </aside>
        );
      case "horizontalRule":
        return <hr key={index} />;
      case "hardBreak":
        return <br key={index} />;
      case "image":
        return (
          <figure
            key={index}
            className={`editorial-figure editorial-width-${node.attrs?.width}`}
          >
            <MediaImage
              id={String(node.attrs?.mediaId)}
              alt={String(node.attrs?.alt)}
            />
            {node.attrs?.caption && (
              <figcaption>{node.attrs.caption}</figcaption>
            )}
          </figure>
        );
      default:
        return null;
    }
  };
  return render(doc, 0);
}
export function NewsCard({
  item,
  base = "/nieuws",
  featured = false,
}: {
  item: NewsItem;
  base?: string;
  featured?: boolean;
}) {
  return (
    <article
      className={`editorial-card${featured ? " editorial-featured" : ""}`}
    >
      <Link
        className="editorial-card-image"
        href={`${base}/${item.slug}`}
        tabIndex={-1}
        aria-hidden="true"
      >
        {item.content.heroId && (
          <MediaImage
            id={item.content.heroId}
            alt=""
            variant={featured ? "hero" : "card"}
          />
        )}
      </Link>
      <div className="editorial-card-body">
        <div className="editorial-meta">
          <span>{item.category || "Uit de wijk"}</span>
          <time dateTime={item.publishedAt}>
            {new Intl.DateTimeFormat("nl-NL", {
              timeZone: "Europe/Amsterdam",
              day: "numeric",
              month: "long",
            }).format(new Date(item.publishedAt))}
          </time>
          {item.channel !== "website" && !item.read && (
            <span className="editorial-badge">Nieuw</span>
          )}
        </div>
        <h2>
          <Link href={`${base}/${item.slug}`}>{item.content.title}</Link>
        </h2>
        <p>{item.content.intro}</p>
        <Link className="editorial-text-link" href={`${base}/${item.slug}`}>
          Lees het verhaal <span aria-hidden="true">→</span>
        </Link>
      </div>
    </article>
  );
}
export function NewsArticle({
  item,
  children,
}: {
  item: NewsItem;
  children?: ReactNode;
}) {
  return (
    <article className="editorial-article">
      <header>
        <p className="kicker">{item.category || "Nachtpost · uit de wijk"}</p>
        <h1>{item.content.title}</h1>
        <p className="editorial-intro">{item.content.intro}</p>
        <div className="editorial-meta">
          <time dateTime={item.publishedAt}>
            {new Intl.DateTimeFormat("nl-NL", {
              timeZone: "Europe/Amsterdam",
              dateStyle: "long",
            }).format(new Date(item.publishedAt))}
          </time>
          {item.content.author && <span>{item.content.author}</span>}
        </div>
      </header>
      {item.content.heroId && (
        <figure className="editorial-hero">
          <MediaImage id={item.content.heroId} alt={item.content.heroAlt} />
          {item.content.heroCaption && (
            <figcaption>{item.content.heroCaption}</figcaption>
          )}
        </figure>
      )}
      <RichContent content={item.content.body} />
      {children ??
        (item.cta && (
          <a href={item.cta.url} className="btn">
            {item.cta.label}
          </a>
        ))}
    </article>
  );
}
