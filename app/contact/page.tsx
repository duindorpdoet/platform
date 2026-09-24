import { PublicRequestForm } from "@/components/forms/public-request-form";

export default function ContactPage() {
  return <div className="page wrap narrow"><div className="page-head"><p className="kicker">Contact</p><h1>Een vraag voor de <em>organisatie?</em></h1><p>Wil je iets weten over aanmelden, de werelden, spanning of meedoen met je huis? Laat een bericht achter. Ben je al ingeschreven? Gebruik dan ook de Messenger via Hulp van de organisatie in jullie persoonlijke omgeving; zo blijft jullie gesprek bij elkaar.</p></div><PublicRequestForm mode="contact" /></div>;
}
