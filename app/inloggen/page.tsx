import { AccountLogin } from "@/components/auth/account-login";
import { safeReturnPath } from "@/lib/auth/redirect";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";

export const metadata = { title: "Inloggen · De Duindorpse Poorten", robots: { index: false, follow: false } };

export const dynamic = "force-dynamic";
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const { next, error } = await searchParams;
  let googleAvailable: boolean | null = null;
  const config = getPublicSupabaseConfig();
  if (config) {
    try {
      const result = await fetch(`${config.url}/auth/v1/settings`, { headers: { apikey: config.publishableKey }, signal: AbortSignal.timeout(3000), cache: "no-store" });
      if (result.ok) googleAvailable = (await result.json()).external?.google === true;
    } catch { /* A provider-status timeout must not disable OTP. */ }
  }
  return <AccountLogin destination={safeReturnPath(next, "/omgeving/kiezen")} googleAvailable={googleAvailable} error={error ? error === "google_cancelled" ? error : "callback" : undefined} />;
}
