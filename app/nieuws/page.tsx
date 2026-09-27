import Link from "next/link";
import { newsFeed } from "@/lib/editorial/server";
import { NewsCard } from "@/components/editorial/news-view";
export const dynamic = "force-dynamic";
export const metadata = {
  title: "Nieuws uit Duindorp",
  description:
    "Verhalen, voorbereidingen en nieuws van De Duindorpse Poorten van Halloween.",
  alternates: { canonical: "/nieuws" },
};
export default async function NewsPage({
  searchParams,
}: {
  searchParams: Promise<{ pagina?: string }>;
}) {
  const page = Math.max(
    1,
    Math.min(400, Number((await searchParams).pagina) || 1),
  );
  const items = await newsFeed("website", undefined, (page - 1) * 24);
  const featured = page === 1 ? items.find((item) => item.featured) : undefined;
  return (
    <div className="page wrap editorial-public">
      <header className="editorial-page-heading">
        <p className="kicker">De wijk schrijft mee</p>
        <h1>Verhalen achter de poorten.</h1>
        <p>
          Het laatste nieuws, de voorpret en de mensen die de nacht mogelijk
          maken.
        </p>
      </header>
      {featured && <NewsCard item={featured} featured />}
      {items.length ? (
        <div className="editorial-grid">
          {items
            .filter((item) => item.id !== featured?.id)
            .map((item) => (
              <NewsCard key={item.id} item={item} />
            ))}
        </div>
      ) : (
        <p>De Redactiekamer bereidt de eerste verhalen voor.</p>
      )}
      <nav className="editorial-actions" aria-label="Nieuwspagina’s">
        {page > 1 && (
          <Link href={`/nieuws?pagina=${page - 1}`} className="btn outline">
            Vorige pagina
          </Link>
        )}
        {items.length === 24 && (
          <Link href={`/nieuws?pagina=${page + 1}`} className="btn outline">
            Volgende pagina
          </Link>
        )}
      </nav>
    </div>
  );
}
