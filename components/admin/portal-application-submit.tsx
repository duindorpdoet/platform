"use client";

import { useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { AdminDialog } from "./admin-dialog";

type Issue = { field: string; message: string; repair?: string };
type Preview = {
  applicationId: string;
  code: string;
  version: number;
  inputHash: string;
  allowed: boolean;
  blockingReasons: Issue[];
  approvalRequirements: Issue[];
  contact: {
    name: string | null;
    email: string | null;
    verified: boolean;
    matchesApplication: boolean;
  };
  consent: { availability: boolean | null; locationConsent: boolean | null };
  statuses: {
    application: { status: string };
    intake: { claimed: boolean; withdrawn: boolean; version: number } | null;
    portal: { lifecycle: string; version: number } | null;
  };
};
type Review = { preview: Preview; key: string };
type Request = {
  _event_slug: string;
  _application_id: string;
  _expected_version: number;
  _input_hash: string;
  _reason: string;
  _idempotency_key: string;
};
const consentLabel = (value: boolean | null) =>
  value === true
    ? "Door bewoner bevestigd"
    : value === false
      ? "Niet bevestigd"
      : "Niet vastgelegd";

export function PortalApplicationSubmit({
  eventSlug,
  applicationId,
  eligible,
  onEdit,
  onChanged,
}: {
  eventSlug: string;
  applicationId: string;
  eligible: boolean;
  onEdit: () => void;
  onChanged: () => Promise<void>;
}) {
  const [review, setReview] = useState<Review | null>(null);
  const [reason, setReason] = useState("");
  const [acknowledged, setAcknowledged] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [uncertain, setUncertain] = useState(false);
  const frozen = useRef<{ review: Review; request: Request } | null>(null);
  const pending = useRef(false);

  async function preview() {
    if (pending.current) return;
    if (frozen.current) {
      setReview(frozen.current.review);
      return;
    }
    const client = createClient();
    if (!client) return;
    pending.current = true;
    setBusy(true);
    setError("");
    try {
      const result = await client
        .schema("api")
        .rpc("admin_portal_application_submit_preview", {
          _event_slug: eventSlug,
          _application_id: applicationId,
        })
        .abortSignal(AbortSignal.timeout(8_000));
      if (result.error) throw result.error;
      setReview({ preview: result.data as Preview, key: crypto.randomUUID() });
      setAcknowledged(false);
      setUncertain(false);
    } catch {
      setError(
        "De actuele aanvraag kon niet worden gecontroleerd. Vernieuw de lijst en probeer opnieuw.",
      );
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }

  async function submit() {
    const client = createClient();
    if (
      !client ||
      !review ||
      pending.current ||
      (!frozen.current &&
        (!acknowledged || reason.trim().length < 10 || !review.preview.allowed))
    )
      return;
    pending.current = true;
    setBusy(true);
    setError("");
    const request = frozen.current?.request ?? {
      _event_slug: eventSlug,
      _application_id: applicationId,
      _expected_version: review.preview.version,
      _input_hash: review.preview.inputHash,
      _reason: reason.trim(),
      _idempotency_key: review.key,
    };
    frozen.current ??= { review, request };
    try {
      const result = await client
        .schema("api")
        .rpc("admin_portal_application_submit", request)
        .abortSignal(AbortSignal.timeout(12_000));
      if (result.error) {
        if (
          !/^(22023|23514|23505|40001|42501)$/.test(result.error.code ?? "") ||
          result.error.message === "SUBMISSION_REPLAY_CONTEXT_CHANGED"
        )
          throw result.error;
        frozen.current = null;
        setUncertain(false);
        setError(
          result.error.code === "40001"
            ? "De aanvraag, identiteit of koppeling is gewijzigd. Vernieuw de preview en controleer de gegevens opnieuw."
            : result.error.code === "42501"
              ? "Je hebt geen actuele toestemming om deze aanvraag in te dienen."
              : result.error.code === "23505"
                ? "Deze opdrachtsleutel hoort bij een andere opdracht. Sluit het venster en controleer de tijdlijn."
                : "Indienen is geblokkeerd. Vernieuw de preview voor de concrete herstelstappen.",
        );
        return;
      }
      frozen.current = null;
      setUncertain(false);
      setReview(null);
      setReason("");
      setAcknowledged(false);
      try {
        await onChanged();
      } catch {
        setError(
          "De indiening is bevestigd. Vernieuw de lijst om de actuele aanvraag te zien.",
        );
      }
    } catch {
      setUncertain(true);
      setError(
        "De uitkomst is nog niet bevestigd. Controleer dezelfde opdracht opnieuw; daarbij blijven de reden en opdrachtsleutel gelijk. De server voert een ontvangen opdracht niet dubbel uit. Na sluiten kun je ook de actuele aanvraag en tijdlijn bekijken.",
      );
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }

  const p = review?.preview;
  return (
    <>
      {(eligible || uncertain) && (
        <button
          type="button"
          className="btn outline"
          disabled={busy}
          onClick={() => void preview()}
        >
          {uncertain
            ? "Uitkomst van indiening controleren"
            : "Namens bewoner indienen"}
        </button>
      )}
      {error && !review && <p role="alert">{error}</p>}
      {review && p && (
        <AdminDialog
          labelledBy={`submit-${applicationId}`}
          close={() => {
            if (!busy) setReview(null);
          }}
        >
          <h2 id={`submit-${applicationId}`}>
            Namens bewoner indienen · {p.code}
          </h2>
          <p>
            <strong>{p.contact.name || "Naam ontbreekt"}</strong> ·{" "}
            {p.contact.email || "Bewonersadres nog niet bevestigd"}
          </p>
          <p>
            Aanvraag {p.applicationId} · versie {p.version}.{" "}
            {p.statuses.application.status === "changes_requested"
              ? "Aanpassing gevraagd"
              : "Concept"}{" "}
            → klaar voor beoordeling.
          </p>
          <section aria-label="Blokkeert indienen">
            <h3>Blokkeert indienen</h3>
            {p.blockingReasons.length ? (
              <ul>
                {p.blockingReasons.map((issue, n) => (
                  <li key={`${issue.field}-${n}`}>{issue.message}</li>
                ))}
              </ul>
            ) : (
              <p>
                De huidige indieningsgegevens en bewonersidentiteit zijn
                gecontroleerd.
              </p>
            )}
            {!uncertain &&
              p.blockingReasons.some((issue) => issue.repair === "edit") && (
                <button
                  type="button"
                  className="btn outline"
                  disabled={busy}
                  onClick={() => {
                    setReview(null);
                    onEdit();
                  }}
                >
                  Aanmeldgegevens aanvullen
                </button>
              )}
            {p.blockingReasons.some((issue) => issue.repair === "resident") && (
              <p>
                De bewoner vult dit aan via Mijn poort en slaat het concept op.
                Open daarna een nieuwe preview.
              </p>
            )}
          </section>
          <section aria-label="Nog nodig vóór goedkeuren">
            <h3>Nog nodig vóór goedkeuren</h3>
            {p.approvalRequirements.length ? (
              <ul>
                {p.approvalRequirements.map((issue) => (
                  <li key={issue.field}>{issue.message}</li>
                ))}
              </ul>
            ) : (
              <p>
                De adres- en toestemmingsgegevens zijn vastgelegd. Inhoudelijke
                beoordeling blijft een aparte stap.
              </p>
            )}
            <p>
              Beschikbaarheid: {consentLabel(p.consent.availability)}.
              Locatietoestemming: {consentLabel(p.consent.locationConsent)}.
            </p>
            <p>
              Alleen de bewoner bevestigt ontbrekende toestemming. Goedkeuring,
              locatiecontrole en activatie blijven afzonderlijke
              beheerhandelingen.
            </p>
          </section>
          <p>
            Dit dient alleen de aanvraag in. De bestaande outbox verwerkt een{" "}
            <strong>portal_received</strong>-ontvangstbevestiging voor de
            geverifieerde bewoner volgens het geldende mailbeleid. De reden en
            jouw beheerhandeling worden geaudit. Er wordt geen poort
            gepubliceerd en er worden geen eigenaarrechten toegekend.
          </p>
          <label className="field">
            <span>Reden voor indienen namens bewoner (10–500 tekens)</span>
            <textarea
              minLength={10}
              maxLength={500}
              value={reason}
              disabled={busy || uncertain}
              onChange={(e) => setReason(e.target.value)}
            />
          </label>
          <label>
            <input
              type="checkbox"
              checked={acknowledged}
              disabled={busy || uncertain}
              onChange={(e) => setAcknowledged(e.target.checked)}
            />{" "}
            Ik bevestig dat ik deze aanvraag bewust namens de bewoner indien.
          </label>
          {error && <p role="alert">{error}</p>}
          <div className="actions">
            <button
              type="button"
              className="btn outline"
              disabled={busy}
              onClick={() => setReview(null)}
            >
              {uncertain ? "Sluiten en tijdlijn bekijken" : "Annuleren"}
            </button>
            {!uncertain && (
              <button
                type="button"
                className="btn outline"
                disabled={busy}
                onClick={() => void preview()}
              >
                Preview vernieuwen
              </button>
            )}
            <button
              type="button"
              className="btn"
              disabled={
                busy ||
                (!uncertain &&
                  (!p.allowed || !acknowledged || reason.trim().length < 10))
              }
              onClick={() => void submit()}
            >
              {busy
                ? "Controleren…"
                : uncertain
                  ? "Uitkomst controleren"
                  : "Indienen voor beoordeling"}
            </button>
          </div>
        </AdminDialog>
      )}
    </>
  );
}
