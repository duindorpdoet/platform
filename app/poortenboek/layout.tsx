import type { Metadata } from "next";
import "./poortenboek.css";
export const dynamic = "force-dynamic";
export const metadata: Metadata = {
  title: "Het Poortenboek · De Duindorpse Poorten",
  robots: { index: false, follow: false },
};
export default function BookLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
