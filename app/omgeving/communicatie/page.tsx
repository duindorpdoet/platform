import { redirect } from "next/navigation";
import Link from "next/link";
import { getActor } from "@/lib/auth/session";
import { CommunicationPreferences } from "@/components/editorial/preferences";
export const dynamic = "force-dynamic";
export const metadata = {
  title: "Communicatievoorkeuren",
  robots: { index: false, follow: false },
};
export default async function PreferencesPage() {
  if (!(await getActor())) redirect("/inloggen?next=/omgeving/communicatie");
  return (
    <div id="participant-content" className="page wrap editorial-public">
      <Link className="editorial-text-link" href="/omgeving">
        ← Mijn omgeving
      </Link>
      <CommunicationPreferences />
    </div>
  );
}
