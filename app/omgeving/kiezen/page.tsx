import Link from "next/link";
import { redirect } from "next/navigation";
import { accountSnapshot } from "@/lib/account/server";
import { ApiError } from "@/lib/http/api";
import { EnvironmentChooser } from "@/components/account/environment-chooser";

export const dynamic = "force-dynamic";
export const metadata = { title: "Kies jouw omgeving · De Poorten", robots: { index: false, follow: false } };
export default async function ChooseEnvironmentPage() {
  let snapshot;
  try { snapshot = await accountSnapshot(); }
  catch (error) {
    if (error instanceof ApiError && error.status === 401) redirect("/inloggen?next=/omgeving/kiezen");
    return <main className="wrap page"><h1>Je omgevingen zijn even niet bereikbaar.</h1><p>Je sessie is niet gewist. Maak verbinding en probeer opnieuw.</p><Link className="btn" href="/omgeving/kiezen">Opnieuw controleren</Link></main>;
  }
  return <EnvironmentChooser initial={snapshot} />;
}
