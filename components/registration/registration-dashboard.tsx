"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Snapshot = {
  event?: { changeDeadline?: string | null; changesOpen: boolean };
  registration?: {
    id: string;
    reference: string;
    status: string;
    priceCents: number;
    version: number;
    children: Array<{
      id: string;
      firstName: string;
      ageAtEvent?: number | null;
      status: string;
      unitPriceCents: number;
    }>;
    changeRequests: Array<{
      id: string;
      kind: string;
      status: string;
      description: string;
      createdAt: string;
      updatedAt: string;
    }>;
    payment?: {
      status: string;
      amountCents: number;
      externalUrl?: string;
      version: number;
    } | null;
  } | null;
};
type PartySnapshot = {
  registrationId: string;
  party: null | {
    id: string;
    label: string;
    memberCount: number;
    locked: boolean;
  };
};
type HouseholdSnapshot = {
  id: string;
  label: string;
  version: number;
  canManage: boolean;
  members: Array<{
    userId: string;
    role: "owner" | "adult";
    email: string;
    acceptedAt: string;
  }>;
  pendingInvites: Array<{
    id: string;
    recipientEmail: string;
    expiresAt: string;
    createdAt: string;
  }>;
};

async function digest(value: unknown) {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(value)),
  );
  return [...new Uint8Array(bytes)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

export function RegistrationDashboard({
  eventSlug,
  inviteToken,
}: {
  eventSlug: string;
  inviteToken?: string;
}) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [party, setParty] = useState<PartySnapshot | null>(null);
  const [household, setHousehold] = useState<HouseholdSnapshot | null>(null);
  const [label, setLabel] = useState("");
  const [code, setCode] = useState("");
  const [createdCode, setCreatedCode] = useState("");
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteProcessing, setInviteProcessing] = useState(
    Boolean(inviteToken),
  );
  const [notice, setNotice] = useState("");
  const inviteAttempted = useRef(false);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const [registrationResult, partyResult, householdResult] =
      await Promise.all([
        client
          .schema("api")
          .rpc("registration_snapshot", { _event_slug: eventSlug }),
        client
          .schema("api")
          .rpc("together_snapshot", { _event_slug: eventSlug }),
        client
          .schema("api")
          .rpc("household_access_snapshot", { _event_slug: eventSlug }),
      ]);
    if (!registrationResult.error)
      setSnapshot(registrationResult.data as Snapshot);
    if (!partyResult.error) setParty(partyResult.data as PartySnapshot | null);
    if (!householdResult.error)
      setHousehold(householdResult.data as HouseholdSnapshot | null);
  }, [eventSlug]);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);
  useEffect(() => {
    if (!inviteToken || inviteAttempted.current) return;
    inviteAttempted.current = true;
    void (async () => {
      const client = createClient();
      if (!client) return;
      const { error } = await client
        .schema("api")
        .rpc("household_invite_accept", { _invite_token: inviteToken });
      window.history.replaceState({}, "", "/mijn-inschrijving");
      setNotice(
        error
          ? "Deze gezinsuitnodiging is ongeldig, verlopen, ingetrokken of hoort bij een ander e-mailadres."
          : "De gezinsuitnodiging is geaccepteerd. Je hebt nu toegang tot deze inschrijving.",
      );
      setInviteProcessing(false);
      await load();
    })();
  }, [inviteToken, load]);
  const registration = snapshot?.registration;
  if (!snapshot)
    return <div className="panel">Inschrijving veilig ophalen…</div>;
  if (inviteProcessing)
    return <div className="panel">Gezinsuitnodiging veilig controleren…</div>;
  if (!registration)
    return (
      <div className="panel empty-state">
        <h2>Geen definitieve inschrijving</h2>
        <p>Je kunt een concept starten via ‘Meelopen’.</p>
        {notice && (
          <p className="form-notice" role="status">
            {notice}
          </p>
        )}
      </div>
    );
  async function reportPayment() {
    const current = snapshot?.registration;
    const client = createClient();
    if (!client || !current?.payment) return;
    const { error } = await client
      .schema("api")
      .rpc("registration_report_payment", {
        _registration_id: current.id,
        _expected_version: current.payment.version,
      });
    setNotice(
      error
        ? "De betaalmelding kon niet worden verwerkt."
        : "Je melding is opgeslagen. De organisatie controleert de betaling handmatig.",
    );
    await load();
  }
  async function createParty() {
    const client = createClient();
    if (!client || !party?.registrationId) return;
    const { data, error } = await client
      .schema("api")
      .rpc("together_create", {
        _registration_id: party.registrationId,
        _label: label,
      });
    if (error) return setNotice("Samenloopgroep maken is niet gelukt.");
    setCreatedCode((data as { inviteCode: string }).inviteCode);
    setNotice(
      "De samenloopwens is opgeslagen. Deel de code veilig met het andere huishouden.",
    );
    await load();
  }
  async function joinParty() {
    const client = createClient();
    if (!client || !party?.registrationId) return;
    const { error } = await client
      .schema("api")
      .rpc("together_join", {
        _registration_id: party.registrationId,
        _invite_code: code,
      });
    setNotice(
      error
        ? "De code is ongeldig, verlopen of al gebruikt voor jouw inschrijving."
        : "Je samenloopwens is gekoppeld.",
    );
    await load();
  }
  async function leaveParty() {
    const client = createClient();
    if (!client || !party?.registrationId || !party.party || party.party.locked)
      return;
    if (
      !window.confirm(
        "Samenloopwens verlaten? De andere huishoudens blijven gekoppeld.",
      )
    )
      return;
    const { error } = await client
      .schema("api")
      .rpc("together_leave", {
        _registration_id: party.registrationId,
        _reason: "Door huishouden zelf verlaten",
      });
    setNotice(
      error
        ? "De samenloopwens kon niet worden verlaten; mogelijk is de indeling al vergrendeld."
        : "Je inschrijving is uit de samenloopwens gehaald. Andere huishoudens zijn niet gewijzigd.",
    );
    if (!error) setCreatedCode("");
    await load();
  }
  async function requestRegistrationChange(
    kind: "correction" | "remove_child" | "cancellation",
    childId?: string,
  ) {
    const current = snapshot?.registration;
    if (!current || current.status !== "submitted") return;
    const promptLabel =
      kind === "cancellation"
        ? "Waarom wil je de volledige inschrijving annuleren?"
        : kind === "remove_child"
          ? "Licht de verwijdering kort toe:"
          : "Welke correctie is nodig?";
    const description = window
      .prompt(`${promptLabel} (minimaal 10 tekens)`)
      ?.trim();
    if (!description || description.length < 10)
      return setNotice("Omschrijf het verzoek in minimaal tien tekens.");
    if (
      kind === "cancellation" &&
      !window.confirm(
        "Volledige annulering aanvragen? Een eventuele terugbetaling wordt altijd apart door de organisatie gecontroleerd.",
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("registration_request_change", {
        _registration_id: current.id,
        _request_kind: kind,
        _description: description,
        _registration_child_id: childId ?? null,
      });
    setNotice(
      error
        ? error.message.includes("REQUEST_ALREADY_OPEN")
          ? "Voor deze wijziging staat al een verzoek open."
          : "Het wijzigingsverzoek kon niet worden opgeslagen."
        : "Je verzoek is opgeslagen. De inschrijving en betaalhistorie wijzigen pas na controle door de organisatie.",
    );
    await load();
  }
  async function createHouseholdInvite() {
    const client = createClient();
    if (!client || !household?.canManage) return;
    const key = crypto.randomUUID();
    const requestHash = await digest({
      eventSlug,
      email: inviteEmail.trim().toLowerCase(),
    });
    const { error } = await client
      .schema("api")
      .rpc("household_invite_create", {
        _event_slug: eventSlug,
        _recipient_email: inviteEmail,
        _idempotency_key: key,
        _request_hash: requestHash,
      });
    setNotice(
      error
        ? "De uitnodiging kon niet worden verstuurd. Controleer het adres of probeer later opnieuw."
        : "De geadresseerde gezinsuitnodiging staat in de verzendwachtrij.",
    );
    if (!error) setInviteEmail("");
    await load();
  }
  async function revokeInvite(id: string) {
    const client = createClient();
    if (!client || !household?.canManage) return;
    const { error } = await client
      .schema("api")
      .rpc("household_invite_revoke", {
        _invite_id: id,
        _expected_household_version: household.version,
        _reason: "Door gezinsbeheerder ingetrokken",
      });
    setNotice(
      error
        ? "De uitnodiging is intussen gewijzigd; de actuele stand is opgehaald."
        : "De uitnodiging is ingetrokken.",
    );
    await load();
  }
  async function revokeMember(userId: string) {
    const client = createClient();
    if (
      !client ||
      !household?.canManage ||
      !window.confirm("Trek de toegang van deze volwassene in?")
    )
      return;
    const { error } = await client
      .schema("api")
      .rpc("household_member_revoke", {
        _event_slug: eventSlug,
        _member_user_id: userId,
        _expected_household_version: household.version,
        _reason: "Door gezinsbeheerder ingetrokken",
      });
    setNotice(
      error
        ? "De gezinstoegang is intussen gewijzigd; de actuele stand is opgehaald."
        : "De toegang van de tweede volwassene is ingetrokken.",
    );
    await load();
  }
  return (
    <div className="dashboard-stack">
      <section className="panel">
        <p className="kicker">Referentie</p>
        <h1>{registration.reference}</h1>
        <div className="summary-row">
          <span>Inschrijving</span>
          <strong>{registration.status}</strong>
        </div>
        <div className="summary-row">
          <span>Totaal</span>
          <strong>
            € {(registration.priceCents / 100).toFixed(2).replace(".", ",")}
          </strong>
        </div>
        <div className="summary-row">
          <span>Betaling</span>
          <strong>{registration.payment?.status ?? "wordt voorbereid"}</strong>
        </div>
        {registration.payment?.externalUrl && (
          <a
            className="btn"
            href={registration.payment.externalUrl}
            target="_blank"
            rel="noreferrer noopener"
          >
            Open de Tikkie-link
          </a>
        )}
        {registration.payment &&
          ["awaiting_link", "awaiting_payment"].includes(
            registration.payment.status,
          ) && (
            <button
              className="btn outline"
              onClick={() => void reportPayment()}
            >
              Ik heb betaald
            </button>
          )}
        <p className="note">
          Alleen een bevoegde organisator kan een betaling bevestigen. Een
          melding van jou is nog geen bevestiging.
        </p>
      </section>
      <section className="panel">
        <p className="kicker">Deelname aanpassen</p>
        <h2>Kinderen en wijzigingen</h2>
        {registration.children.map((child) => (
          <div className="summary-row" key={child.id}>
            <span>
              {child.firstName} · {child.status}
            </span>
            {child.status === "active" &&
            registration.status === "submitted" ? (
              <button
                className="text-link"
                onClick={() =>
                  void requestRegistrationChange("remove_child", child.id)
                }
              >
                Verwijdering aanvragen
              </button>
            ) : (
              <strong>{child.status}</strong>
            )}
          </div>
        ))}
        {registration.status === "submitted" && (
          <div className="actions">
            <button
              className="btn outline"
              onClick={() => void requestRegistrationChange("correction")}
            >
              Correctie aanvragen
            </button>
            <button
              className="btn outline"
              onClick={() => void requestRegistrationChange("cancellation")}
            >
              Annulering aanvragen
            </button>
          </div>
        )}
        <p className="note">
          {snapshot.event?.changeDeadline
            ? `Wijzigingsdeadline: ${new Date(snapshot.event.changeDeadline).toLocaleString("nl-NL")}. `
            : ""}
          {snapshot.event?.changesOpen
            ? "Een ingediend verzoek wordt gecontroleerd voordat bedragen of deelnemers wijzigen."
            : "De wijzigingsperiode is gesloten; iedere aanpassing loopt daarom via de organisatie."}
        </p>
        {registration.changeRequests.map((request) => (
          <div className="summary-row" key={request.id}>
            <span>
              {request.kind.replaceAll("_", " ")} · {request.description}
            </span>
            <strong>{request.status}</strong>
          </div>
        ))}
      </section>
      <section className="panel">
        <p className="kicker">Gezinstoegang</p>
        <h2>{household?.label ?? "Gezin"}</h2>
        {household?.members.map((member) => (
          <div className="summary-row" key={member.userId}>
            <span>
              {member.email} ·{" "}
              {member.role === "owner" ? "beheerder" : "volwassene"}
            </span>
            {household.canManage && member.role === "adult" ? (
              <button
                className="text-link"
                onClick={() => void revokeMember(member.userId)}
              >
                Trek toegang in
              </button>
            ) : (
              <strong>actief</strong>
            )}
          </div>
        ))}
        {household?.canManage && (
          <>
            <div className="separator" />
            <label className="field">
              <span>E-mailadres tweede volwassene</span>
              <input
                type="email"
                autoComplete="email"
                value={inviteEmail}
                onChange={(event) => setInviteEmail(event.target.value)}
              />
            </label>
            <button
              className="btn outline"
              disabled={
                !inviteEmail.includes("@") ||
                household.pendingInvites.length >= 3
              }
              onClick={() => void createHouseholdInvite()}
            >
              Verstuur eenmalige uitnodiging
            </button>
            {household.pendingInvites.map((invite) => (
              <div className="summary-row" key={invite.id}>
                <span>
                  {invite.recipientEmail} · geldig tot{" "}
                  {new Date(invite.expiresAt).toLocaleDateString("nl-NL")}
                </span>
                <button
                  className="text-link"
                  onClick={() => void revokeInvite(invite.id)}
                >
                  Intrekken
                </button>
              </div>
            ))}
          </>
        )}
        <p className="note">
          Een uitnodiging werkt eenmaal, alleen voor het geadresseerde account,
          en vervalt automatisch.
        </p>
      </section>
      <section className="panel">
        <p className="kicker">Samen lopen</p>
        <h2>Samenloopwens</h2>
        {party?.party ? (
          <>
            <p>
              Je bent gekoppeld aan <strong>{party.party.label}</strong> met{" "}
              {party.party.memberCount} inschrijving(en).
            </p>
            {createdCode && (
              <div className="registration-code">{createdCode}</div>
            )}
            <p className="note">
              De routeplanner houdt de wens bij elkaar zolang capaciteit en
              veiligheid dat toelaten.
            </p>
            <button
              className="text-link"
              disabled={party.party.locked}
              onClick={() => void leaveParty()}
            >
              {party.party.locked
                ? "Samenloopwens is vergrendeld"
                : "Verlaat samenloopwens"}
            </button>
          </>
        ) : (
          <>
            <label className="field">
              <span>Nieuwe samenloopgroep</span>
              <input
                value={label}
                onChange={(event) => setLabel(event.target.value)}
                placeholder="Bijvoorbeeld: Familie aan zee"
              />
            </label>
            <button
              className="btn outline"
              disabled={!label.trim()}
              onClick={() => void createParty()}
            >
              Maak uitnodigingscode
            </button>
            <div className="separator" />
            <label className="field">
              <span>Ontvangen code</span>
              <input
                value={code}
                onChange={(event) => setCode(event.target.value.toUpperCase())}
              />
            </label>
            <button
              className="btn outline"
              disabled={!code.trim()}
              onClick={() => void joinParty()}
            >
              Koppel samenloopwens
            </button>
          </>
        )}
        {notice && (
          <p className="form-notice" role="status">
            {notice}
          </p>
        )}
      </section>
    </div>
  );
}
