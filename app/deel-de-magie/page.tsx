import type { Metadata } from "next";
import { ShareStudio } from "@/components/social-share/share-studio";

export const metadata: Metadata = {
  title: "Maak jouw deelkaart",
  description: "Maak een professionele deelkaart voor De Duindorpse Poorten van Halloween.",
};

export default function ShareStudioPage() {
  return (
    <div className="share-page">
      <header className="share-hero">
        <div className="share-hero-backdrop" />
        <div className="wrap share-hero-content">
          <p className="kicker">Deel de magie</p>
          <h1>Maak jouw <em>deelkaart</em></h1>
          <p>Kies jouw moment. Wij bouwen er een cinematografische kaart van, klaar om veilig te bewaren en te delen.</p>
        </div>
      </header>
      <main className="wrap"><ShareStudio /></main>
    </div>
  );
}
