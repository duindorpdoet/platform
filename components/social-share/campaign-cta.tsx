"use client";

import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { rememberShareCampaign, type CampaignKind } from "@/lib/social-share/client-analytics";

export function CampaignCta({ href, label, publicShareId, kind }: { href: string; label: string; publicShareId: string; kind?: CampaignKind }) {
  return <Link className="btn" href={href} onClick={() => { if (kind) rememberShareCampaign({ publicShareId, kind }); }}>{label}<ArrowRight size={18} /></Link>;
}
