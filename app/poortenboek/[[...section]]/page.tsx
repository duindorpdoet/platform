import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { Poortenboek } from "@/components/poortenboek/book";
import { childSnapshot } from "@/lib/poortenboek/server";
import type { BookSection } from "@/lib/poortenboek/model";
import { getActor } from "@/lib/auth/session";
import { ParentPoortenboek } from "@/components/poortenboek/parent";
export default async function BookPage({
  params,
}: {
  params: Promise<{ section?: string[] }>;
}) {
  const { section } = await params;
  const tab = section?.[0] ?? "nu";
  if ((section?.length ?? 0) > 1 || !["nu", "team", "boek", "ik"].includes(tab))
    notFound();
  const snapshot = await childSnapshot();
  if (!snapshot) {
    if (await getActor()) return <main className="container"><ParentPoortenboek /><Link href="/omgeving/meeloper">Terug naar mijn ouderomgeving</Link><p><Link href="/poortenboek/inloggen">Zelf inloggen met een kindcode</Link></p></main>;
    redirect("/poortenboek/inloggen");
  }
  return <Poortenboek initial={snapshot} section={tab as BookSection} />;
}
