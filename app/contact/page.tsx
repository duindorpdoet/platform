import { PublicRequestForm } from "@/components/forms/public-request-form";

export default function ContactPage() {
  return <div className="page wrap narrow"><div className="page-head"><p className="kicker">Contact</p><h1>Een vraag voor de <em>organisatie?</em></h1><p>Gebruik het formulier. Op de avond zelf verschijnt hier alleen geverifieerde operationele informatie.</p></div><PublicRequestForm mode="contact" /></div>;
}
