import { notFound } from "next/navigation";
import { PortalInvitation } from "@/components/portal/portal-invitation";
export const dynamic = "force-dynamic";
export const metadata = {
  title: "Een sleutel voor De Poortkamer",
  robots: { index: false, follow: false },
  referrer: "no-referrer" as const,
};
export default async function InvitationPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  if (!/^[a-f0-9]{64}$/.test(token)) notFound();
  return <PortalInvitation token={token} />;
}
