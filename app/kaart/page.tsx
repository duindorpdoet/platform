import { ConceptNotice, PageHeading } from "@/components/brand/public-page";
import { PublicMap } from "@/components/maps/public-map";

export const metadata = { title: "Kaart · De Duindorpse Poorten" };

export default function MapPage() {
  return (
    <div className="wrap page map-page">
      <PageHeading eyebrow="DE WIJK ONTWAAKT" title="Een sfeerkaart van Duindorp." intro="De openbare kaart toont alleen het evenementgebied en expliciet vrijgegeven informatie." />
      <ConceptNotice>Toekomstige bestemmingen, privé-adressen en routevolgorde worden pas aan de bevoegde groep vrijgegeven.</ConceptNotice>
      <PublicMap />
    </div>
  );
}
