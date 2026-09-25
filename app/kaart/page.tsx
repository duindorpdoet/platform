import { ConceptNotice, PageHeading } from "@/components/brand/public-page";
import { PublicMap } from "@/components/maps/public-map";

export const metadata = { title: "Kaart · De Duindorpse Poorten" };

export default function MapPage() {
  return (
    <div className="wrap page map-page">
      <PageHeading eyebrow="DE WIJK ONTWAAKT" title="Zie de nacht tot leven komen." intro="Ontdek hoe poorten tijdens de Halloween-avond verschijnen en hoe een route door de wijk kan veranderen. Beweeg over een poort of tik erop voor het verhaal erachter." />
      <ConceptNotice>Dit is een fictieve live-demonstratie met verzonnen poorten en voorbeeldroutes. Echte deelnemers, privéadressen en definitieve routes blijven verborgen.</ConceptNotice>
      <PublicMap />
    </div>
  );
}
