import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./frightnight.css";
import "maplibre-gl/dist/maplibre-gl.css";
import { ServiceWorkerRegistration } from "@/components/pwa/service-worker-registration";
import { FrightNightSession } from "@/components/frightnight/session";

export const metadata: Metadata = {
  title: { default: "Duindorp FrightNight 2027 · De nacht is van ons", template: "%s · FrightNight 2027" },
  description: "De Vloek van de Pompoenkoning. Een middag vol licht en een avond vol avontuur in Duindorp. Zaterdag 30 oktober 2027, start en finale op het Duinpad.",
  manifest: "/manifest.webmanifest",
  icons: { icon: "/frightnight/king-head.webp", apple: "/frightnight/icon-192.png" },
  appleWebApp: { capable: true, title: "FrightNight", statusBarStyle: "black-translucent" },
  applicationName: "Duindorp FrightNight 2027",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000"),
};
export const viewport: Viewport = { themeColor: "#081712", viewportFit: "cover" };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="nl" className="dark frightnight-root"><body><a className="skip-link" href="#main-content">Direct naar de inhoud</a><ServiceWorkerRegistration /><FrightNightSession />{children}</body></html>;
}
