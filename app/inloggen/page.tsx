import { AccountLogin } from "@/components/auth/account-login";
import { safeReturnPath } from "@/lib/auth/redirect";
import {googleAvailability} from '@/lib/auth/providers';

export const metadata = { title: "Inloggen · De Duindorpse Poorten", robots: { index: false, follow: false } };

export const dynamic = "force-dynamic";
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const { next, error } = await searchParams;
  const googleAvailable=await googleAvailability();
  return <AccountLogin destination={safeReturnPath(next, "/omgeving/kiezen")} googleAvailable={googleAvailable} error={error ? error === "google_cancelled" ? error : "callback" : undefined} />;
}
