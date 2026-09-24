"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { ParticipantPayment } from "@/components/payments/payment-details";
import { ChildPaymentRows, type ChildPayment } from "@/components/payments/child-payment-rows";
import { createClient } from "@/lib/supabase/client";

type Snapshot = {
  event?: { changeDeadline?: string | null; changesOpen: boolean; maxGroupSize: number };
  registration?: {
    id: string;
    reference: string;
    status: string;
    priceCents: number;
    togetherCode: string;
    togetherCount: number;
    togetherRequest?: {
      id: string;
      status: "pending" | "accepted" | "rejected";
      requestedCode: string;
      projectedChildren: number;
      maxGroupSize: number;
      limitOverridden: boolean;
      updatedAt: string;
    } | null;
    version: number;
    children: Array<{
      id: string;
      childId?: string;
      firstName: string;
      ageAtEvent?: number | null;
      status: string;
      unitPriceCents: number;
      payment?: ChildPayment | null;
    }>;
    changeRequests: Array<{
      id: string;
      kind: string;
      status: string;
      description: string;
      createdAt: string;
      updatedAt: string;
    }>;
    payment?: ParticipantPayment | null;
  } | null;
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
type PreferenceSnapshot = {
  registrationId: string | null;
  version: number | null;
  startPreference: "early" | "indifferent" | "later";
  ordinaryStopAt: string | null;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  editable: boolean;
  changeStatus: "editable" | "locked" | "change_requested";
  confirmedSchedule?: { startsAt: string; startPoint: string; startAddress: string; effectiveOrdinaryStopAt: string; expectedFinaleArrivalAt: string; revision: number } | null;
  event: { firstStartAt?: string | null; globalOrdinaryStopAt?: string | null; allowedStopTimes: string[]; allowedStartTimes: string[]; allowedEndTimes: string[] };
};

const registrationStatusLabels: Record<string, string> = {
  draft: "Concept",
  submitted: "Ingeschreven",
  cancelled: "Geannuleerd",
};

const paymentStatusLabels: Record<string, string> = {
  awaiting_link: "Wacht op Tikkie",
  awaiting_payment: "Wacht op betaling",
  reported: "Betaling gemeld",
  confirmed: "Betaald",
  partial: "Deels betaald",
  refund_due: "Terugbetaling volgt",
  refunded: "Terugbetaald",
  waived: "Geen betaling nodig",
};

const childStatusLabels: Record<string, string> = {
  active: "Aangemeld",
  cancelled: "Afgezegd",
};

const changeKindLabels: Record<string, string> = {
  correction: "Correctie",
  remove_child: "Kind afmelden",
  cancellation: "Annulering",
};

const changeStatusLabels: Record<string, string> = {
  open: "In behandeling",
  acknowledged: "Gezien",
  resolved: "Afgerond",
  rejected: "Afgewezen",
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
  const [household, setHousehold] = useState<HouseholdSnapshot | null>(null);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteProcessing, setInviteProcessing] = useState(
    Boolean(inviteToken),
  );
  const [notice, setNotice] = useState("");
  const [preferences, setPreferences] = useState<PreferenceSnapshot | null>(null);
  const [preferenceDraft, setPreferenceDraft] = useState<{ preferredStartAt: string; desiredEndAt: string }>({ preferredStartAt: "", desiredEndAt: "" });
  const inviteAttempted = useRef(false);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const [registrationResult, householdResult, preferenceResult] =
      await Promise.all([
        client
          .schema("api")
          .rpc("registration_snapshot", { _event_slug: eventSlug }),
        client
          .schema("api")
          .rpc("household_access_snapshot", { _event_slug: eventSlug }),
        client
          .schema("api")
          .rpc("registration_preferences_snapshot", { _event_slug: eventSlug }),
      ]);
    if (!registrationResult.error)
      setSnapshot(registrationResult.data as Snapshot);
    if (!householdResult.error)
      setHousehold(householdResult.data as HouseholdSnapshot | null);
    if (!preferenceResult.error) {
      const next = preferenceResult.data as PreferenceSnapshot;
      setPreferences(next);
      setPreferenceDraft({ preferredStartAt: next.preferredStartAt ?? "", desiredEndAt: next.desiredEndAt ?? next.ordinaryStopAt ?? "" });
    }
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
  async function savePreferences() {
    if (!preferences?.registrationId || preferences.version === null) return;
    const client = createClient(); if (!client) return;
    if (!preferenceDraft.desiredEndAt) return setNotice("Kies wanneer jullie met gewone poorten willen stoppen.");
    const args = {
      _registration_id: preferences.registrationId,
      _preferred_start_at: preferenceDraft.preferredStartAt || null,
      _desired_end_at: preferenceDraft.desiredEndAt,
    };
    const result = preferences.editable
      ? await client.schema("api").rpc("registration_exact_preferences_save", { ...args, _expected_version: preferences.version })
      : await client.schema("api").rpc("registration_exact_preferences_request_change", {
          ...args,
          _reason: window.prompt("Waarom wil je de bevestigde voorkeur aanpassen? (minimaal 10 tekens)")?.trim() ?? "",
        });
    setNotice(result.error
      ? result.error.message.includes("PREFERENCES_LOCKED") ? "De indeling is intussen gesloten. Verstuur hiervoor een wijzigingsverzoek." : "De voorkeur kon niet worden verwerkt."
      : preferences.editable ? "Start- en stopvoorkeur bijgewerkt." : "Wijzigingsverzoek naar de organisatie verstuurd.");
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
      <section className="panel registration-overview-card">
        <p className="kicker">Referentie</p>
        <h1 className="registration-reference">{registration.reference}</h1>
        <div className="summary-row">
          <span>Inschrijving</span>
          <strong>{registrationStatusLabels[registration.status] ?? registration.status}</strong>
        </div>
        <div className="summary-row">
          <span>Totaal</span>
          <strong>
            € {(registration.priceCents / 100).toFixed(2).replace(".", ",")}
          </strong>
        </div>
        <div className="summary-row">
          <span>Betaling</span>
          <strong>{registration.payment ? paymentStatusLabels[registration.payment.status] ?? registration.payment.status : "Wordt voorbereid"}</strong>
        </div>
        <p className="note">
          Alleen een bevoegde organisator kan een betaling bevestigen. Een
          melding van jou is nog geen bevestiging.
        </p>
      </section>
      {preferences && <section className="panel">
        <p className="kicker">Start en einde</p><h2>Jullie voorkeuren</h2>
        {preferences.confirmedSchedule && <div className="form-notice"><strong>Bevestigde indeling · revisie {preferences.confirmedSchedule.revision}</strong><br />Start: {new Date(preferences.confirmedSchedule.startsAt).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Amsterdam" })} bij {preferences.confirmedSchedule.startPoint}, {preferences.confirmedSchedule.startAddress}.<br />Geen nieuwe gewone poorten vanaf {new Date(preferences.confirmedSchedule.effectiveOrdinaryStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}; verwachte aankomst laatste poort circa {new Date(preferences.confirmedSchedule.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}.</div>}
        <label className="field"><span>Gewenste starttijd</span><select value={preferenceDraft.preferredStartAt} onChange={(event) => setPreferenceDraft({ ...preferenceDraft, preferredStartAt: event.target.value })}><option value="">Maakt niet uit</option>{preferences.event.allowedStartTimes.map((value) => <option value={value} key={value}>{new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</option>)}</select><small>Dit blijft een voorkeur totdat de organisatie een exacte start bevestigt.</small></label>
        <label className="field"><span>Wanneer stoppen jullie met gewone poorten?</span><select required value={preferenceDraft.desiredEndAt} onChange={(event) => setPreferenceDraft({ ...preferenceDraft, desiredEndAt: event.target.value })}><option value="">Kies een tijd</option>{preferences.event.allowedEndTimes.map((value) => <option value={value} key={value} disabled={Boolean(preferences.confirmedSchedule && new Date(value) <= new Date(preferences.confirmedSchedule.startsAt))}>{new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</option>)}</select><small>Het bezoek aan de laatste poort volgt daarna nog.</small></label>
        <button className="btn outline" onClick={() => void savePreferences()}>{preferences.editable ? "Voorkeuren opslaan" : "Wijziging aanvragen"}</button>
        {preferences.changeStatus === "change_requested" && <p className="note">Jullie wijzigingsverzoek wacht op beoordeling door de organisatie.</p>}
      </section>}
      <section className="panel">
        <p className="kicker">Deelname aanpassen</p>
        <h2>Kinderen en wijzigingen</h2>
        <ChildPaymentRows items={registration.children} registrationId={registration.id} legacyPayment={registration.payment} reload={load} additionalAction={(child) => child.status === "active" && registration.status === "submitted"
          ? <button className="text-link" onClick={() => void requestRegistrationChange("remove_child", child.id)}>Verwijdering aanvragen</button>
          : <strong>{childStatusLabels[child.status] ?? child.status}</strong>} />
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
            ? `Wijzigingsdeadline: ${new Date(snapshot.event.changeDeadline).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })}. `
            : ""}
          {snapshot.event?.changesOpen
            ? "Een ingediend verzoek wordt gecontroleerd voordat bedragen of deelnemers wijzigen."
            : "De wijzigingsperiode is gesloten; iedere aanpassing loopt daarom via de organisatie."}
        </p>
        {registration.changeRequests.map((request) => (
          <div className="summary-row" key={request.id}>
            <span>
              {changeKindLabels[request.kind] ?? request.kind.replaceAll("_", " ")} · {request.description}
            </span>
            <strong>{changeStatusLabels[request.status] ?? request.status}</strong>
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
      <section className="panel together-code-card">
        <p className="kicker">Samen lopen</p>
        <h2>Jullie samenloopcode</h2>
        <p>Deel deze code met bekenden die nog moeten inschrijven. Zij vullen hem tijdens hun inschrijving in.</p>
        <div className="registration-code together-share-code" aria-label={`Samenloopcode ${registration.togetherCode}`}>{registration.togetherCode}</div>
        <p className="note">
          {registration.togetherCount > 1
            ? `${registration.togetherCount} inschrijvingen zijn na goedkeuring met deze hoofdgroep verbonden en delen één start, route en laatste poort.`
            : "Er zijn nog geen andere inschrijvingen definitief aan jullie hoofdgroep gekoppeld."}
        </p>
        <p className="note">
          De ingestelde groepsgrens is maximaal {snapshot.event?.maxGroupSize ?? 10} kinderen. Iedere aanvraag blijft apart totdat de organisatie capaciteit en veiligheid heeft gecontroleerd en de koppeling expliciet goedkeurt.
        </p>
        {registration.togetherRequest?.status === "pending" && (
          <div className="form-warning">
            Jullie verzoek om bij code {registration.togetherRequest.requestedCode} aan te sluiten is nog niet goedgekeurd. Samen zouden jullie {registration.togetherRequest.projectedChildren} kinderen zijn; de organisatie controleert capaciteit, tijden en veiligheid.
          </div>
        )}
        {registration.togetherRequest?.status === "rejected" && (
          <div className="form-notice">
            De organisatie heeft de gevraagde koppeling met code {registration.togetherRequest.requestedCode} afgewezen. Jullie eigen inschrijving blijft geldig.
          </div>
        )}
        {registration.togetherRequest?.status === "accepted" && registration.togetherRequest.limitOverridden && (
          <div className="form-notice">
            De organisatie heeft jullie samenloopwens als gecontroleerde uitzondering geaccepteerd.
          </div>
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
