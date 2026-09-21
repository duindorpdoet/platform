import Link from "next/link";
import { RegistrationWizard } from "@/components/registration/registration-wizard";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function RegistrationPage() {
  const actor = await getActor();
  const env = serverEnv();
  return <div className="page wrap registration-page"><section className="registration-intro"><p className="kicker">Loop mee · 31 oktober 2026</p><h1>Word onderdeel van <em>het verhaal.</em></h1><p>€ 2 per kind. Een volwassene loopt mee. Je groep en starttijd volgen pas nadat de organisatie de indeling expliciet publiceert.</p><div className="registration-facts"><p><strong>Veilig:</strong> toekomstige poorten blijven verborgen.</p><p><strong>Eerlijk:</strong> betaling wordt handmatig gecontroleerd.</p><p><strong>Herstelbaar:</strong> ieder concept wordt tussentijds opgeslagen.</p></div></section>{actor ? <RegistrationWizard eventSlug={env.EVENT_SLUG} canSubmit={env.REGISTRATION_MODE !== "closed"} /> : <div className="panel auth-required"><h2>Log veilig in om te beginnen</h2><p>We sturen een zescijferige eenmalige code naar je e-mailadres.</p><Link className="btn" href="/inloggen?next=/meelopen">Inloggen met e-mailcode</Link>{env.REGISTRATION_MODE === "closed" && <p className="note">De definitieve inschrijving is nog gesloten.</p>}</div>}</div>;
}
