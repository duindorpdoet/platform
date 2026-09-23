import type { Metadata } from "next";
import "./globals.css";
import "./cinematic.css";
import "./experience.css";
import "./home.css";
import "maplibre-gl/dist/maplibre-gl.css";
import { SiteChrome } from "@/components/brand/site-chrome";
import { ServiceWorkerRegistration } from "@/components/pwa/service-worker-registration";

export const metadata: Metadata = {
  title: "De Duindorpse Poorten van Halloween · 31 oktober 2026",
  description: "Een magische Halloween-avondloop door Duindorp op 31 oktober 2026. Loop samen langs versierde huizen, portieken en buurtbedrijven.",
  manifest: "/manifest.webmanifest",
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
  applicationName: "De Duindorpse Poorten van Halloween",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000"),
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="nl" className="dark">
      <body className="antialiased">
        <ServiceWorkerRegistration />
        <SiteChrome>{children}</SiteChrome>
      </body>
    </html>
  );
}
