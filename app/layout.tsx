import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./cinematic.css";
import "./experience.css";
import "./home.css";
import "./route-map.css";
import "./maps.css";
import "./worlds.css";
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
    apple: [{ url: "/pwa/icons/apple-touch-icon-180.png", sizes: "180x180", type: "image/png" }],
  },
  appleWebApp: {
    capable: true,
    title: "De Poorten",
    statusBarStyle: "black-translucent",
    startupImage: [
      { url: "/pwa/splash/iphone/iphone-750x1334.png", media: "screen and (device-width: 375px) and (device-height: 667px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-828x1792.png", media: "screen and (device-width: 414px) and (device-height: 896px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1080x2340.png", media: "screen and (device-width: 360px) and (device-height: 780px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1125x2436.png", media: "screen and (device-width: 375px) and (device-height: 812px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1170x2532.png", media: "screen and (device-width: 390px) and (device-height: 844px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1179x2556.png", media: "screen and (device-width: 393px) and (device-height: 852px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1206x2622.png", media: "screen and (device-width: 402px) and (device-height: 874px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1242x2688.png", media: "screen and (device-width: 414px) and (device-height: 896px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1260x2736.png", media: "screen and (device-width: 420px) and (device-height: 912px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1284x2778.png", media: "screen and (device-width: 428px) and (device-height: 926px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1290x2796.png", media: "screen and (device-width: 430px) and (device-height: 932px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/iphone/iphone-1320x2868.png", media: "screen and (device-width: 440px) and (device-height: 956px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-1536x2048.png", media: "screen and (device-width: 768px) and (device-height: 1024px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2048x1536.png", media: "screen and (device-width: 768px) and (device-height: 1024px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-1620x2160.png", media: "screen and (device-width: 810px) and (device-height: 1080px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2160x1620.png", media: "screen and (device-width: 810px) and (device-height: 1080px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-1640x2360.png", media: "screen and (device-width: 820px) and (device-height: 1180px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2360x1640.png", media: "screen and (device-width: 820px) and (device-height: 1180px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-1668x2388.png", media: "screen and (device-width: 834px) and (device-height: 1194px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2388x1668.png", media: "screen and (device-width: 834px) and (device-height: 1194px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-1668x2420.png", media: "screen and (device-width: 834px) and (device-height: 1210px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2420x1668.png", media: "screen and (device-width: 834px) and (device-height: 1210px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-2048x2732.png", media: "screen and (device-width: 1024px) and (device-height: 1366px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2732x2048.png", media: "screen and (device-width: 1024px) and (device-height: 1366px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
      { url: "/pwa/splash/ipad/ipad-2064x2752.png", media: "screen and (device-width: 1032px) and (device-height: 1376px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" },
      { url: "/pwa/splash/ipad/ipad-2752x2064.png", media: "screen and (device-width: 1032px) and (device-height: 1376px) and (-webkit-device-pixel-ratio: 2) and (orientation: landscape)" },
    ],
  },
  applicationName: "De Duindorpse Poorten van Halloween",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000"),
};

export const viewport: Viewport = {
  themeColor: "#08101e",
  viewportFit: "cover",
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
