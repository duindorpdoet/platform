import { PageHeading } from "@/components/brand/public-page";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { safeReturnPath } from "@/lib/auth/redirect";

export const metadata = { title: "Inloggen · De Duindorpse Poorten", robots: { index: false, follow: false } };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  return (
    <div className="wrap page auth-page">
      <PageHeading eyebrow="VEILIG TERUG NAAR JOUW AVOND" title="Inloggen met e-mail." intro="Je identiteit wordt door Supabase gecontroleerd; rechten komen uit de database, niet uit een rollenknop." />
      <EmailOtpForm nextPath={safeReturnPath(next)} />
    </div>
  );
}
