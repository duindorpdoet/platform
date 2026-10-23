import Link from "next/link";
import { notFound } from "next/navigation";
import { getWorld, worlds } from "@/features/content/public-content";

export function generateStaticParams() {
  return worlds.map(({ slug }) => ({ slug }));
}

export default async function WorldPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const world = getWorld(slug);
  if (!world) notFound();
  const index = worlds.indexOf(world);

  return (
    <div className="world-detail" style={{ "--world": world.color } as React.CSSProperties}>
      <img className="detail-art world-detail-art" src={`/images/world-${index}.webp`} alt={world.name} />
      <div className="wrap detail-layout">
        <Link className="back" href="/werelden">← Alle werelden</Link>
        <div className="detail-copy"><p className="kicker">{world.subtitle}</p><h1>{world.name}</h1><p className="lead">{world.story}</p><div className="panel"><span className="label">Spanningsniveau</span><h3>{world.intensity} / 4</h3><div className="warning-tags">{world.warnings.map(warning=><span key={warning}>{warning}</span>)}</div></div><Link className="btn" href="/meelopen">Bekijk deelname →</Link></div>
      </div>
    </div>
  );
}
