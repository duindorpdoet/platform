import { PageHeading } from "@/components/brand/public-page";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { safeReturnPath } from "@/lib/auth/redirect";

export const metadata = { title: "Inloggen · De Duindorpse Poorten", robots: { index: false, follow: false } };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  return (
    <div className="wrap page auth-page">
      <PageHeading eyebrow="VEILIG TERUG NAAR JOUW AVOND" title="Inloggen met e-mail." intro="Vul je e-mailadres in en ontvang een eenmalige code. Zo kom je zonder wachtwoord bij je inschrijving, groep of aangemelde plek." />
      <EmailOtpForm nextPath={safeReturnPath(next)} />
    </div>
  );
}
