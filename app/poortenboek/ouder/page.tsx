import Link from "next/link";
import { redirect } from "next/navigation";
import { getActor } from "@/lib/auth/session";
import { ParentPoortenboek } from "@/components/poortenboek/parent";

export const dynamic = "force-dynamic";

export default async function ParentBooksPage() {
  if (!await getActor()) redirect("/inloggen?next=%2Fpoortenboek%2Fouder");
  return <main className="container"><ParentPoortenboek /><p><Link href="/omgeving/meeloper">Terug naar mijn ouderomgeving</Link></p><p><Link href="/poortenboek/inloggen">Zelf inloggen met een kindcode</Link></p></main>;
}
