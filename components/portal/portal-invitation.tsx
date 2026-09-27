"use client";
import Image from "next/image";
import { useState } from "react";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { createClient } from "@/lib/supabase/client";
import s from "./poortkamer.module.css";
export function PortalInvitation({ token }: { token: string }) {
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  async function accept() {
    const client = createClient();
    if (!client || busy) return;
    setBusy(true);
    setNotice("");
    try {
      const { error } = await client
        .schema("api")
        .rpc("portal_invitation_accept", { _token: token });
      if (error) {
        setNotice(
          "Deze sleutel kon niet worden aangenomen. Gebruik precies het uitgenodigde e-mailadres, of vraag de hoofdpoortwachter een nieuwe uitnodiging.",
        );
        return;
      }
      window.location.replace("/mijn-huis");
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className={s.room}>
      <main className={`${s.content} ${s.teaser}`}>
        <Image
          className={s.cardImage}
          src="/images/poortkamer/share-a-key.webp"
          width={720}
          height={540}
          alt=""
        />
        <p className={s.eyebrow}>Er ligt een sleutel voor je klaar</p>
        <h1>Welkom achter de poort</h1>
        <p>
          Bevestig het e-mailadres waarop je deze persoonlijke uitnodiging
          ontving. Daarna kun je bij het team.
        </p>
        <EmailOtpForm
          onVerified={accept}
          beforeRequestCode={async (email) => {
            const response = await fetch("/api/poortkamer/invitation", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ token, email }),
            });
            if (!response.ok) throw new Error("INVITATION_UNAVAILABLE");
          }}
        />
        <div className={s.card}>
          <p>Al ingelogd met het uitgenodigde adres?</p>
          <button
            className={`${s.button} ${s.primary}`}
            disabled={busy}
            onClick={() => void accept()}
          >
            {busy ? "Sleutel controleren…" : "Sleutel aannemen"}
          </button>
          {notice && <p role="alert">{notice}</p>}
        </div>
      </main>
    </div>
  );
}
