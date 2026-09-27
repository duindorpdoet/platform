import Link from "next/link";
import { serverEnv } from "@/lib/config/server-env";
import { verifyEditorialToken } from "@/lib/editorial/security";
export const dynamic = "force-dynamic";
export const metadata = {
  title: "Nachtpost afmelden",
  robots: { index: false, follow: false },
};
export default async function UnsubscribePage({
  searchParams,
}: {
  searchParams: Promise<{ token?: string; klaar?: string }>;
}) {
  const query = await searchParams;
  const valid =
    query.token &&
    serverEnv().EDITORIAL_TOKEN_SECRET &&
    verifyEditorialToken(
      serverEnv().EDITORIAL_TOKEN_SECRET!,
      "unsubscribe",
      query.token,
    );
  return (
    <div className="page wrap">
      <section className="panel" style={{ maxWidth: 680, margin: "40px auto" }}>
        <p className="kicker">Nachtpost · jouw voorkeur</p>
        <h1>
          {query.klaar === "1" ? "Je bent afgemeld" : "Afmelden voor Nachtpost"}
        </h1>
        <p>
          Belangrijke berichten over jouw deelname, betaling en starttijd
          blijven gewoon beschikbaar.
        </p>
        {query.klaar === "1" ? (
          <p>Je ontvangt geen volgende redactionele nieuwsbrief meer.</p>
        ) : valid ? (
          <form
            action={`/api/editorial/unsubscribe?token=${encodeURIComponent(query.token!)}&return=page`}
            method="post"
          >
            <button className="btn" type="submit">
              Afmelden voor Nachtpost
            </button>
          </form>
        ) : (
          <p>
            Gebruik de afmeldlink uit jouw Nachtpost, of pas je voorkeuren aan
            in je account.
          </p>
        )}
        <p>
          <Link href="/omgeving/communicatie">Naar communicatievoorkeuren</Link>
        </p>
      </section>
    </div>
  );
}
