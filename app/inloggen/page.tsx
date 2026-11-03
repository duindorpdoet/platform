import { FestivalLogin } from "@/components/frightnight/login";
import { safeReturnPath } from "@/lib/auth/redirect";
import {googleAvailability} from '@/lib/auth/providers';

export const metadata = { title: "Inloggen · FrightNight 2027", robots: { index: false, follow: false } };

export const dynamic = "force-dynamic";
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const { next, error } = await searchParams;
  const googleAvailable=await googleAvailability();
  return <FestivalLogin destination={safeReturnPath(next, "/nachtpas")} googleAvailable={googleAvailable} error={error ? error === "google_cancelled" ? error : "callback" : undefined} />;
}
