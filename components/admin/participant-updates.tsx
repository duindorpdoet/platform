"use client";

import { useState } from "react";
import { BellRing, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

export function ParticipantUpdates({ eventSlug }: { eventSlug: string }) {
  const [role, setRole] = useState("all");
  const [priority, setPriority] = useState("normal");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [email, setEmail] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  async function publish() {
    if (title.trim().length < 3 || body.trim().length < 3) return setNotice("Vul een duidelijke titel en berichttekst in.");
    if (!window.confirm(`Publiceer deze update voor ${role === "all" ? "alle rollen" : role} ${email ? "en verstuur e-mail volgens de voorkeuren" : "zonder e-mail"}?`)) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_publish_participant_update", {
      _event_slug: eventSlug,
      _audience_role: role,
      _title: title.trim(),
      _body: body.trim(),
      _priority: priority,
      _send_email: email,
    });
    setBusy(false);
    if (error) return setNotice("Publiceren is niet gelukt. Controleer je rechten en probeer opnieuw.");
    const result = data as { emailCount: number };
    setTitle(""); setBody("");
    setNotice(`Update gepubliceerd${email ? ` en ${result.emailCount} e-mailmelding${result.emailCount === 1 ? "" : "en"} klaargezet` : ""}.`);
  }

  return <section className="panel">
    <div className="row-between"><div><p className="kicker">Rolgerichte communicatie</p><h2>Deelnemersupdates</h2><p>Publiceer alleen operationele informatie die deze doelgroep nodig heeft. Leesstatus wordt per account bijgehouden.</p></div><BellRing /></div>
    <div className="grid-2">
      <label className="field"><span>Doelgroep</span><select value={role} onChange={(event) => setRole(event.target.value)}><option value="all">Alle rollen</option><option value="walker">Meelopers</option><option value="viewer">Meekijkers</option><option value="homeowner">Huiseigenaren</option></select></label>
      <label className="field"><span>Prioriteit</span><select value={priority} onChange={(event) => setPriority(event.target.value)}><option value="normal">Normaal</option><option value="important">Belangrijk</option><option value="urgent">Urgent</option></select></label>
    </div>
    <label className="field"><span>Titel</span><input maxLength={120} value={title} onChange={(event) => setTitle(event.target.value)} /></label>
    <label className="field"><span>Bericht</span><textarea rows={6} maxLength={1200} value={body} onChange={(event) => setBody(event.target.value)} /></label>
    <label className="checkfield"><input type="checkbox" checked={email} onChange={(event) => setEmail(event.target.checked)} />Stuur ook e-mail naar accounts die e-mailupdates aan hebben staan.</label>
    <button className="btn" disabled={busy || title.trim().length < 3 || body.trim().length < 3} onClick={() => void publish()}><Send />Publiceer update</button>
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </section>;
}
