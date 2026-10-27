import Link from "next/link";
import { redirect } from "next/navigation";
import { accountClient } from "@/lib/account/server";
import { ApiError } from "@/lib/http/api";
import { EntryHeader } from "@/components/auth/account-login";
import { InstallControls } from "@/components/pwa/install-controls";
import { PushNotificationSettings } from "@/components/pwa/pwa-experience";
import { WelcomeReplayButton } from "@/components/account/navigation";
export const dynamic="force-dynamic";
export default async function AppSettingsPage(){
 try{await accountClient();}catch(error){if(error instanceof ApiError&&error.status===401)redirect('/inloggen?next=/app/meldingen');return <main className="wrap page"><h1>Maak verbinding om je meldingen veilig te beheren.</h1><Link href="/app/meldingen">Opnieuw proberen</Link></main>}
 return <div className="entry-page entry-choice-page"><EntryHeader/><main className="entry-choice-wrap"><h1>App & meldingen</h1><p>Installeren, WhatsApp en meldingen zijn vrijwillig. De toestemming en apparaatinschrijving hieronder gelden voor dit apparaat.</p><InstallControls/><PushNotificationSettings/><WelcomeReplayButton/><p><Link href="/omgeving/kiezen">Wissel omgeving</Link> · <Link href="/app/hulp">Hulp bij de app</Link></p></main></div>;
}
