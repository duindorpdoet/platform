import Link from "next/link";
import { ArrowRight } from "lucide-react";

export function PageHeading({ eyebrow, title, intro }: { eyebrow: string; title: string; intro: string }) {
  return (
    <header className="page-head">
      <p className="kicker">{eyebrow}</p>
      <h1>{title}</h1>
      <p>{intro}</p>
    </header>
  );
}

export function ConceptNotice({ children }: { children: React.ReactNode }) {
  return <div className="info-box concept-notice" role="status">{children}</div>;
}

export function SignInCallout({ returnTo }: { returnTo: string }) {
  return (
    <div className="panel center auth-callout">
      <h2>Bewaar je aanvraag veilig.</h2>
      <p>Log in met een eenmalige code per e-mail. Zo kun je later verder en ziet niemand anders je gegevens.</p>
      <Link className="btn" href={`/inloggen?next=${encodeURIComponent(returnTo)}`}>Inloggen met e-mail <ArrowRight size={17} /></Link>
    </div>
  );
}
