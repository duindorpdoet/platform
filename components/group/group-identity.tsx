"use client";

import { useState } from "react";
import { Check, Clipboard, Pencil } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

export function GroupIdentity({
  groupId,
  systemCode,
  displayName,
  version,
  canEdit,
  onSaved,
}: {
  groupId: string;
  systemCode: string;
  displayName?: string | null;
  version: number;
  canEdit: boolean;
  onSaved: () => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(displayName ?? "");
  const [notice, setNotice] = useState("");
  const [copied, setCopied] = useState(false);

  async function copyCode() {
    await navigator.clipboard.writeText(systemCode);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  }

  async function save() {
    const normalized = name.trim().replace(/\s+/g, " ");
    if (normalized.length < 2 || normalized.length > 80) return setNotice("Kies een groepsnaam van 2 tot en met 80 tekens.");
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("group_name_update", {
      _group_id: groupId,
      _expected_version: version,
      _display_name: normalized,
    });
    if (error) setNotice(error.message.includes("STALE_VERSION") ? "De groep is intussen gewijzigd. Probeer opnieuw met de actuele gegevens." : "De groepsnaam kon niet worden opgeslagen.");
    else { setNotice("Groepsnaam opgeslagen."); setEditing(false); await onSaved(); }
  }

  return <section className="participant-card group-identity-card">
    <div>
      <p className="participant-eyebrow">Eén groep · samen op pad</p>
      <h2>{displayName || `Groep ${systemCode}`}</h2>
      <p>Jullie groepsnaam maakt de tocht persoonlijk. De vaste G-code helpt de organisatie jullie terug te vinden. Samen aansluiten gaat via de aparte samenloopcode, na goedkeuring.</p>
    </div>
    <div className="group-code-panel"><span className="group-code-caption">Groepscode</span><strong>{systemCode}</strong><button className="btn outline" onClick={() => void copyCode()}>{copied ? <Check /> : <Clipboard />}{copied ? "Gekopieerd" : "Kopieer systeemcode"}</button></div>
    {canEdit && <div className="group-name-editor">{editing ? <><label className="participant-field"><span>Zelfgekozen groepsnaam</span><input value={name} maxLength={80} onChange={(event) => setName(event.target.value)} /></label><div className="actions"><button className="btn" onClick={() => void save()}><Check />Opslaan</button><button className="btn outline" onClick={() => { setName(displayName ?? ""); setEditing(false); }}>Annuleren</button></div></> : <button className="btn outline" onClick={() => setEditing(true)}><Pencil />Groepsnaam aanpassen</button>}</div>}
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </section>;
}
