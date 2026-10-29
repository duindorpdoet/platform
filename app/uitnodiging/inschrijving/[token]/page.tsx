import { notFound } from "next/navigation";
import { RegistrationActivation } from "@/components/registration/registration-activation";
import { googleAvailability } from "@/lib/auth/providers";

export const dynamic = "force-dynamic";
export const metadata = {
  title: "Jullie inschrijving activeren · De Poorten",
  robots: { index: false, follow: false },
  referrer: "no-referrer" as const,
};

export default async function RegistrationInvitationPage({ params, searchParams }: {
  params: Promise<{ token: string }>; searchParams: Promise<{ verified?: string }>;
}) {
  const [{ token }, query] = await Promise.all([params, searchParams]);
  if (!/^[a-f0-9]{64}$/.test(token)) notFound();
  return <RegistrationActivation token={token} verified={query.verified === "1"} googleAvailable={await googleAvailability()} />;
}
