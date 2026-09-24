"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Pencil, RefreshCw, ShieldCheck, UserPlus } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

const capabilityOptions = [
  {
    value: "event_admin",
    label: "Hoofdbeheer",
    description: "Beheerders en alle onderdelen van het evenement beheren.",
  },
  {
    value: "registration_manage",
    label: "Inschrijvingen",
    description: "Inschrijfkanalen en wijzigingsverzoeken beheren.",
  },
  {
    value: "payments_manage",
    label: "Betalingen",
    description: "Betalingen controleren, koppelen en corrigeren.",
  },
  {
    value: "portals_manage",
    label: "Locaties",
    description: "Aanmeldingen van woningen, portieken en bedrijven beoordelen.",
  },
  {
    value: "groups_manage",
    label: "Groepen en routes",
    description: "Groepen indelen, leiders kiezen en routes publiceren.",
  },
  {
    value: "live_support",
    label: "Avondondersteuning",
    description: "Tijdens de avond groepen ondersteunen en noodhandelingen uitvoeren.",
  },
  {
    value: "content_manage",
    label: "Content en sponsors",
    description: "Bezoekerspagina’s en sponsorvermeldingen publiceren.",
  },
] as const;

type Capability = (typeof capabilityOptions)[number]["value"];
type AccessMember = {
  userId: string;
  email: string;
  displayName?: string | null;
  capabilities: Capability[];
};
type AccessSnapshot = {
  actorUserId: string;
  members: AccessMember[];
};

const allCapabilities = capabilityOptions.map((option) => option.value);
const capabilityLabel = new Map(
  capabilityOptions.map((option) => [option.value, option.label]),
);

function errorMessage(message: string) {
  if (message.includes("CONFIRMED_USER_REQUIRED"))
    return "Dit e-mailadres heeft nog geen bevestigd account. Laat deze persoon eerst eenmaal met de e-mailcode inloggen.";
  if (message.includes("LAST_EVENT_ADMIN"))
    return "De laatste hoofdbeheerder kan niet worden verwijderd. Maak eerst een andere hoofdbeheerder aan.";
  if (message.includes("STALE_VERSION"))
    return "De rechten zijn intussen ergens anders gewijzigd. Ververs de lijst en probeer het opnieuw.";
  if (message.includes("NOT_AUTHORIZED"))
    return "Alleen een hoofdbeheerder mag beheerdersrechten wijzigen.";
  return "De rechten konden niet worden opgeslagen. Controleer de gegevens en probeer het opnieuw.";
}

export function AdminAccessManagement({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<AccessSnapshot | null>(null);
  const [email, setEmail] = useState("");
  const [selected, setSelected] = useState<Capability[]>(allCapabilities);
  const [expected, setExpected] = useState<Capability[]>([]);
  const [editingUserId, setEditingUserId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [noticeIsError, setNoticeIsError] = useState(false);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_access_snapshot", { _event_slug: eventSlug });
    if (error) {
      setNoticeIsError(true);
      setNotice(errorMessage(error.message));
      return;
    }
    setSnapshot(data as AccessSnapshot);
  }, [eventSlug]);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  const eventAdminCount = useMemo(
    () =>
      snapshot?.members.filter((member) =>
        member.capabilities.includes("event_admin"),
      ).length ?? 0,
    [snapshot],
  );
  const editingMember = snapshot?.members.find(
    (member) => member.userId === editingUserId,
  );
  const protectsLastAdmin = Boolean(
    editingMember?.capabilities.includes("event_admin") &&
      eventAdminCount === 1,
  );

  function resetForm() {
    setEmail("");
    setSelected(allCapabilities);
    setExpected([]);
    setEditingUserId(null);
  }

  function edit(member: AccessMember) {
    setEmail(member.email);
    setSelected(member.capabilities);
    setExpected(member.capabilities);
    setEditingUserId(member.userId);
    setNotice("");
  }

  function toggle(capability: Capability) {
    setSelected((current) =>
      current.includes(capability)
        ? current.filter((item) => item !== capability)
        : [...current, capability],
    );
  }

  async function save() {
    const normalizedEmail = email.trim().toLowerCase();
    if (!/^\S+@\S+\.\S+$/.test(normalizedEmail)) {
      setNoticeIsError(true);
      setNotice("Vul een geldig e-mailadres in.");
      return;
    }
    if (
      selected.length === 0 &&
      !window.confirm(
        `Alle beheerdersrechten van ${normalizedEmail} intrekken?`,
      )
    )
      return;

    setBusy(true);
    setNotice("");
    const client = createClient();
    if (!client) {
      setBusy(false);
      return;
    }
    const { data, error } = await client
      .schema("api")
      .rpc("admin_set_user_capabilities", {
        _event_slug: eventSlug,
        _email: normalizedEmail,
        _capabilities: selected,
        _expected_capabilities: expected,
        _reason: "Beheerdersrechten bijgewerkt via beheeromgeving",
      });
    setBusy(false);
    if (error) {
      setNoticeIsError(true);
      setNotice(errorMessage(error.message));
      return;
    }
    const result = data as { changed: boolean };
    setNoticeIsError(false);
    setNotice(
      result.changed
        ? `De rechten van ${normalizedEmail} zijn bijgewerkt en vastgelegd in de auditlog.`
        : `De rechten van ${normalizedEmail} waren al actueel.`,
    );
    resetForm();
    await load();
  }

  return (
    <div className="admin-access-stack">
      <section className="panel">
        <p className="kicker">Toegang met controle</p>
        <div className="row-between admin-access-heading">
          <div>
            <h2>Beheerders en rechten</h2>
            <p>
              Voeg alleen mensen toe die al eenmaal met hun e-mailadres zijn
              ingelogd. Kies per persoon precies wat nodig is; iedere wijziging
              wordt vastgelegd.
            </p>
          </div>
          <button className="btn outline" type="button" onClick={() => void load()}>
            <RefreshCw />
            Vernieuwen
          </button>
        </div>
        <div className="admin-access-members">
          {!snapshot ? (
            <p className="loading-state">
              <RefreshCw className="spin" /> Rechten ophalen…
            </p>
          ) : snapshot.members.length === 0 ? (
            <p>Nog geen actieve beheerders of medewerkers.</p>
          ) : (
            snapshot.members.map((member) => (
              <article className="admin-access-member" key={member.userId}>
                <div>
                  <strong>{member.displayName || member.email}</strong>
                  {member.displayName && <small>{member.email}</small>}
                  <div className="admin-access-tags">
                    {member.capabilities.map((capability) => (
                      <span className="status blue" key={capability}>
                        {capabilityLabel.get(capability) ?? capability}
                      </span>
                    ))}
                  </div>
                </div>
                <button
                  className="btn outline"
                  type="button"
                  onClick={() => edit(member)}
                >
                  <Pencil />
                  Bewerken
                </button>
              </article>
            ))
          )}
        </div>
      </section>

      <section className="panel admin-access-editor">
        <p className="kicker">
          {editingUserId ? "Rechten aanpassen" : "Beheerder toevoegen"}
        </p>
        <h2>
          {editingUserId ? "Kies de nieuwe rechten." : "Voeg een bevestigd account toe."}
        </h2>
        <label className="field">
          <span>E-mailadres</span>
          <input
            type="email"
            value={email}
            readOnly={Boolean(editingUserId)}
            autoComplete="email"
            placeholder="naam@voorbeeld.nl"
            onChange={(event) => setEmail(event.target.value)}
          />
          <small>
            Nieuwe gebruikers loggen eerst eenmaal in via de gewone inlogpagina.
          </small>
        </label>
        <fieldset className="form-fieldset admin-capability-fieldset" disabled={busy}>
          <legend>Rechten</legend>
          <div className="admin-capability-grid">
            {capabilityOptions.map((option) => {
              const lastAdminCapability =
                option.value === "event_admin" && protectsLastAdmin;
              return (
                <label className="admin-capability-option" key={option.value}>
                  <input
                    type="checkbox"
                    checked={selected.includes(option.value)}
                    disabled={lastAdminCapability}
                    onChange={() => toggle(option.value)}
                  />
                  <span>
                    <strong>{option.label}</strong>
                    <small>{option.description}</small>
                    {lastAdminCapability && (
                      <small className="admin-capability-protection">
                        Dit is de laatste hoofdbeheerder en kan daarom niet worden
                        uitgeschakeld.
                      </small>
                    )}
                  </span>
                </label>
              );
            })}
          </div>
        </fieldset>
        {notice && (
          <p className={noticeIsError ? "form-warning" : "form-notice"} role={noticeIsError ? "alert" : "status"}>
            {notice}
          </p>
        )}
        <div className="actions">
          <button
            className="btn"
            type="button"
            disabled={busy || !email.trim()}
            onClick={() => void save()}
          >
            {editingUserId ? <ShieldCheck /> : <UserPlus />}
            {busy ? "Opslaan…" : editingUserId ? "Rechten opslaan" : "Beheerder toevoegen"}
          </button>
          {editingUserId && (
            <button className="btn outline" type="button" disabled={busy} onClick={resetForm}>
              Annuleren
            </button>
          )}
        </div>
      </section>
    </div>
  );
}
