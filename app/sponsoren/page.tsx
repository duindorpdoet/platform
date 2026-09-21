import { PublicRequestForm } from "@/components/forms/public-request-form";

export default function SponsorPage() {
  return <div className="page wrap"><div className="contact-grid"><div><div className="page-head"><p className="kicker">Samen voor Duindorp</p><h1>Help de poorten <em>opengaan.</em></h1><p>Materiaal, expertise en financiële bijdragen zijn welkom. Een voorstel is pas definitief na beoordeling door de organisatie.</p></div><div className="panel"><h2>Transparant en lokaal</h2><p>We leggen afspraken en betalingen vast in eurocenten. Handmatige betalingen worden uitsluitend door bevoegde organisatoren bevestigd.</p></div></div><PublicRequestForm mode="sponsor" /></div></div>;
}
