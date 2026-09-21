import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, ArrowRight, Flame, LockKeyhole, TriangleAlert } from "lucide-react";
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
        <Link className="back" href="/werelden"><ArrowLeft size={16} /> Alle werelden</Link>
        <div className="detail-copy">
          <p className="kicker">WERELD {String(index + 1).padStart(2, "0")} · {world.subtitle}</p>
          <h1>{world.name}</h1>
          <p className="lead">{world.story}</p>
          <div className="panel">
            <span className="label">SPANNINGSNIVEAU</span>
            <div className="threat"><Flame /> {world.intensity} / 4</div>
            <div className="warning-tags">{world.warnings.map((warning) => <span key={warning}><TriangleAlert size={14} />{warning}</span>)}</div>
          </div>
          <p className="muted"><LockKeyhole size={17} /> Goedgekeurde teasers kunnen hier verschijnen. Exacte adressen en de route van een groep blijven afgeschermd.</p>
          <Link className="btn" href="/meelopen">Bekijk deelname <ArrowRight size={16} /></Link>
        </div>
      </div>
    </div>
  );
}
