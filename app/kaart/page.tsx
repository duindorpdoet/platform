import { ConceptNotice, PageHeading } from "@/components/brand/public-page";
import { PublicMap } from "@/components/maps/public-map";

export const metadata = { title: "Kaart · De Duindorpse Poorten" };

export default function MapPage() {
  return (
    <div className="wrap page map-page">
      <PageHeading eyebrow="DE WIJK ONTWAAKT" title="Waar begint jullie avontuur?" intro="Bekijk de buurt waar de Halloween-avondloop plaatsvindt. De kaart geeft sfeer en richting, de verrassingen bewaren we voor de avond zelf." />
      <ConceptNotice>De kaart laat de buurt zien, maar nog niet welke huizen meedoen. Zo blijven de poorten een echte verrassing.</ConceptNotice>
      <PublicMap />
    </div>
  );
}
