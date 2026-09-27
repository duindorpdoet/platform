import { notFound, redirect } from "next/navigation";
import Link from "next/link";
import { getActor } from "@/lib/auth/session";
import { newsFeed } from "@/lib/editorial/server";
import type { NewsChannel } from "@/lib/editorial/content";
import { NewsArticle } from "@/components/editorial/news-view";
import { PortalNews } from "@/components/editorial/portal-news";
import { NewsInteraction } from "@/components/editorial/news-interaction";
export const dynamic = "force-dynamic";
export const metadata = {
  title: "Nieuws in jouw omgeving",
  robots: { index: false, follow: false },
};
export default async function PortalNewsPage({
  params,
  searchParams,
}: {
  params: Promise<{ path?: string[] }>;
  searchParams: Promise<{ push?: string; device?: string }>;
}) {
  const segments = (await params).path ?? [];
  const { push, device } = await searchParams;
  const subscriptionId =
    device && /^[a-f0-9-]{36}$/.test(device) ? device : undefined;
  const notificationId =
    push && /^[a-f0-9-]{36}$/.test(push) ? push : undefined;
  const target = `/omgeving/nieuws/${segments.join("/")}${notificationId ? `?push=${notificationId}${subscriptionId ? `&device=${subscriptionId}` : ""}` : ""}`;
  if (!(await getActor()))
    redirect(`/inloggen?next=${encodeURIComponent(target)}`);
  const hasChannel = ["ouders", "huizen"].includes(segments[0]);
  const channel: NewsChannel = segments[0] === "huizen" ? "houses" : "parents";
  const slug = hasChannel ? segments[1] : segments[0];
  if (segments.length > (hasChannel ? 2 : 1)) notFound();
  const items = slug ? await newsFeed(channel, slug) : [];
  // Generic push links resolve only within channels accessible to this account.
  if (!hasChannel && slug && !items.length)
    items.push(...(await newsFeed("houses", slug)));
  if (slug && !items.length) notFound();
  return (
    <div id="participant-content" className="page wrap editorial-public">
      <nav className="editorial-actions">
        <Link href="/omgeving" className="editorial-text-link">
          ← Mijn omgeving
        </Link>
        <Link href="/omgeving/communicatie" className="editorial-text-link">
          Communicatievoorkeuren
        </Link>
      </nav>
      {slug ? (
        <NewsArticle item={items[0]}>
          <NewsInteraction
            item={items[0]}
            notificationId={notificationId}
            subscriptionId={subscriptionId}
          />
        </NewsArticle>
      ) : (
        <PortalNews channel={channel} />
      )}
    </div>
  );
}
