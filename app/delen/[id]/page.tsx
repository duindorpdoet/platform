import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { ShieldCheck } from "lucide-react";
import { PublicShareTracker } from "@/components/social-share/public-share-tracker";
import { CampaignCta } from "@/components/social-share/campaign-cta";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";

type SharePage = {
  id: string; title: string; description: string; ctaType: "event" | "registration" | "house_registration";
  campaign?: string; noindex: boolean; templateKey: string; templateName: string; format: string; generationId: string;
};

async function sharePage(id: string) {
  if (!/^[a-f0-9]{32}$/.test(id)) return null;
  const client = await createClient();
  if (!client) return null;
  const result = await client.schema("api").rpc("social_share_public_page", { _public_share_id: id });
  return result.error ? null : result.data as unknown as SharePage | null;
}

function cta(page: SharePage): { href: string; label: string; kind?: "house_registration" | "participant_registration" } {
  const query = new URLSearchParams({ utm_source: "deelstudio", utm_medium: "social", ...(page.campaign ? { utm_campaign: page.campaign } : {}) }).toString();
  if (page.ctaType === "house_registration") return { href: `/huis-aanmelden?${query}`, label: "Meld jouw huis aan", kind: "house_registration" as const };
  if (page.ctaType === "registration") return { href: `/meelopen?${query}`, label: page.templateKey === "join_us" ? "Schrijf je in en vraag daarna persoonlijk de code" : "Bekijk de avondtocht", kind: "participant_registration" as const };
  return { href: "/", label: page.templateKey === "general_event" ? "Bekijk alle informatie" : "Bekijk het evenement" };
}

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }): Promise<Metadata> {
  const { id } = await params;
  const page = await sharePage(id);
  if (!page) return { title: "Deelkaart niet gevonden", robots: { index: false, follow: false } };
  const origin = new URL(serverEnv().APP_URL || serverEnv().NEXT_PUBLIC_SITE_URL || "http://localhost:3000").origin;
  const canonical = `${origin}/delen/${page.id}`;
  const image = `${origin}/api/deelstudio/public/${page.id}/image?kind=opengraph`;
  return {
    title: page.title,
    description: page.description,
    alternates: { canonical },
    robots: { index: !page.noindex && serverEnv().APP_ENVIRONMENT === "production", follow: true },
    openGraph: { type: "website", url: canonical, title: page.title, description: page.description, images: [{ url: image, width: 1200, height: 630, alt: page.title }] },
    twitter: { card: "summary_large_image", title: page.title, description: page.description, images: [image] },
  };
}

export default async function PublicSharePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const page = await sharePage(id);
  if (!page) notFound();
  const action = cta(page);
  return (
    <div className="public-share-page">
      <PublicShareTracker publicShareId={page.id} />
      <main className="wrap public-share-wrap">
        <div className="public-share-brand"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" /></div>
        <article className="public-share-card">
          <div className="public-share-image"><img src={`/api/deelstudio/public/${page.id}/image?kind=asset`} alt={page.title} /></div>
          <div className="public-share-copy"><p className="kicker">Deel de magie</p><h1>{page.title}</h1><p>{page.description}</p><CampaignCta href={action.href} label={action.label} publicShareId={page.id} kind={action.kind} /><p className="public-share-safe"><ShieldCheck size={18} /> Deze openbare pagina bevat geen adressen, kindgegevens of persoonlijke samenloopcode.</p></div>
        </article>
      </main>
    </div>
  );
}
