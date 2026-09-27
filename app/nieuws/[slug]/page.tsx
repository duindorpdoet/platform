import { notFound } from "next/navigation";
import Link from "next/link";
import type { Metadata } from "next";
import { newsFeed } from "@/lib/editorial/server";
import { getPublicSiteUrl } from "@/lib/config/public-env";
import { NewsArticle } from "@/components/editorial/news-view";
import { NewsInteraction } from "@/components/editorial/news-interaction";
export const dynamic = "force-dynamic";
export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const [article] = await newsFeed("website", slug);
  if (!article)
    return {
      title: "Bericht niet gevonden",
      robots: { index: false, follow: false },
    };
  const url = new URL(`/nieuws/${article.slug}`, getPublicSiteUrl()).href;
  return {
    title: article.content.title,
    description: article.content.intro,
    alternates: { canonical: url },
    openGraph: {
      title: article.content.title,
      description: article.content.intro,
      type: "article",
      url,
      publishedTime: article.publishedAt,
      images: article.content.heroId
        ? [
            {
              url: new URL(
                `/api/editorial/media/${article.content.heroId}/og`,
                getPublicSiteUrl(),
              ).href,
              width: 1200,
              height: 630,
              alt: article.content.heroAlt,
            },
          ]
        : [],
    },
  };
}
export default async function NewsDetail({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const [item] = await newsFeed("website", (await params).slug);
  if (!item) notFound();
  return (
    <div className="page wrap editorial-public">
      <Link className="editorial-text-link" href="/nieuws">
        ← Alle nieuws
      </Link>
      <NewsArticle item={item}>
        <NewsInteraction item={item} />
      </NewsArticle>
    </div>
  );
}
