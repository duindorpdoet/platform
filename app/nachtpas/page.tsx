import { ParticipantApp } from "@/components/frightnight/participant";
export const metadata = { title: "Mijn Nachtpas", robots: { index: false, follow: false } };
export default async function Page({ searchParams }: { searchParams: Promise<{ tab?: string; tocht?: string; testinvite?: string }> }) {
  const { tab, tocht, testinvite } = await searchParams;
  const initialTab = ["avontuur", "nachtpas", "plein", "samen", "gegevens", "hulp"].includes(tab ?? "") ? tab : "avontuur";
  return <ParticipantApp initialTestInvite={testinvite && testinvite.length <= 10000 ? testinvite : undefined} initialTab={initialTab} initialRoute={tocht === "scary" ? "roots" : "lantern"} />;
}
