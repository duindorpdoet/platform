import Link from "next/link";
import { newsFeed } from "@/lib/editorial/server";
import { NewsCard } from "./news-view";
export async function HomeNews() {
  const items = await newsFeed("website");
  if (!items.length) return null;
  const featured = items.find((item) => item.featured);
  return (
    <section className="wrap editorial-feed">
      <div className="editorial-section-heading">
        <div>
          <p className="kicker">Uit de wijk · voor de nacht</p>
          <h2>Achter de poorten gebeurt het.</h2>
        </div>
        <Link href="/nieuws" className="editorial-text-link">
          Alle verhalen →
        </Link>
      </div>
      {featured && <NewsCard item={featured} featured />}
      <div className="editorial-grid">
        {items
          .filter((item) => item.id !== featured?.id)
          .slice(0, 3)
          .map((item) => (
            <NewsCard key={item.id} item={item} />
          ))}
      </div>
    </section>
  );
}
