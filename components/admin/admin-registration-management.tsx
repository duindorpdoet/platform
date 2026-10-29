"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { ArrowRightLeft, Mail, Pencil, Plus, RefreshCw, Trash2, X } from "lucide-react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { createClient } from "@/lib/supabase/client";
import {
  registrationActivationLabel, registrationAdminError, registrationChildChanges, registrationChildrenInput, registrationMailStatus,
  type AdminRegistration, type ManagedRegistrationGroup, type RegistrationChildDraft, type RegistrationCreationOptions, type RegistrationManagementPreview,
} from "@/lib/domain/admin-registrations";
import "./admin-registration-management.css";

type Saved = () => Promise<void>;
type Action = "edit" | "move" | "resend" | "email";
const time = (value: string | null | undefined) => value ? new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "nog niet vastgesteld";
const money = (cents: number) => new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
const groupLabel = (group: ManagedRegistrationGroup | null | undefined) => group ? `${group.name || "Groep"} · ${group.code}` : "Nog geen loopgroep";
const blankChild = (): RegistrationChildDraft => ({ key: crypto.randomUUID(), id: null, name: "", age: "", accessibilityNote: "", stepFreeRequired: false });
function safeError(error: unknown) {
  return registrationAdminError(error && typeof error === "object" ? error as { message?: string; code?: string; details?: string } : null);
}
async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const client = createClient();
  if (!client) throw new Error("CLIENT_UNAVAILABLE");
  const result = await client.schema("api").rpc(name, args);
  if (result.error) throw result.error;
  return result.data as T;
}
function useCommandId() {
  const previous = useRef<{ signature: string; id: string } | null>(null);
  return (payload: unknown) => {
    const signature = JSON.stringify(payload);
    if (previous.current?.signature !== signature) previous.current = { signature, id: crypto.randomUUID() };
    return previous.current.id;
  };
}
function ManagementDialog({ title, description, busy, onClose, children }: { title: string; description: string; busy: boolean; onClose: () => void; children: ReactNode }) {
  return <Dialog open onOpenChange={open => { if (!open && !busy) onClose(); }}>
    <DialogContent className="registration-manage-dialog" showCloseButton={false} onEscapeKeyDown={event => { if (busy) event.preventDefault(); }} onPointerDownOutside={event => { if (busy) event.preventDefault(); }}>
      <button className="registration-manage-close" type="button" aria-label="Venster sluiten" disabled={busy} onClick={onClose}><X aria-hidden="true" /></button>
      <div className="registration-manage-heading"><p className="kicker">Inschrijvingen · organisatie</p><DialogTitle>{title}</DialogTitle><DialogDescription>{description}</DialogDescription></div>
      {children}
    </DialogContent>
  </Dialog>;
}
function Notice({ message, error = false }: { message: string; error?: boolean }) {
  const element = useRef<HTMLParagraphElement>(null);
  useEffect(() => { if (error && message) element.current?.focus(); }, [error, message]);
  return message ? <p ref={element} tabIndex={-1} className={error ? "form-warning" : "form-notice"} role={error ? "alert" : "status"}>{message}</p> : null;
}
function ChildrenFields({ drafts: children, setChildren, busy }: { drafts: RegistrationChildDraft[]; setChildren: (children: RegistrationChildDraft[]) => void; busy: boolean }) {
  function update(key: string, values: Partial<RegistrationChildDraft>) { setChildren(children.map(child => child.key === key ? { ...child, ...values } : child)); }
  return <fieldset className="registration-manage-children" disabled={busy}><legend>Kinderen</legend>
    {children.map((child, index) => <div className="registration-manage-child" key={child.key}>
      <div className="row-between"><strong>Kind {index + 1}</strong><button className="text-link" type="button" aria-label={`Deelname kind ${index + 1} verwijderen`} onClick={() => setChildren(children.filter(item => item.key !== child.key))}><Trash2 aria-hidden="true" />Verwijder deelname</button></div>
      <div className="two-fields"><label className="field"><span>Voornaam kind {index + 1}</span><input required maxLength={80} autoComplete="off" value={child.name} onChange={event => update(child.key, { name: event.target.value })} /></label><label className="field"><span>Leeftijd kind {index + 1} op de avond</span><input required type="number" min={0} max={20} step={1} value={child.age} onChange={event => update(child.key, { age: event.target.value })} /></label></div>
      <label className="field"><span>Drempelvrije route voor kind {index + 1}</span><select value={child.stepFreeRequired===true?"required":child.stepFreeRequired===false?"not_required":"review"} onChange={event=>update(child.key,{stepFreeRequired:event.target.value==="required"?true:event.target.value==="not_required"?false:null})}><option value="review">Nog beoordelen · geen automatische aanname</option><option value="not_required">Geen drempelvrije route-eis opgegeven</option><option value="required">Drempelvrije route nodig</option></select></label>
      {child.stepFreeRequired==null&&Boolean(child.accessibilityNote.trim())&&<p className="form-warning">Nog te beoordelen. Een vrije opmerking bewijst geen drempelvrije route-eis. Voorlopig alleen aantoonbaar drempelvrije poorten; ontbrekende verificatie blokkeert goedkeuring. Controleer de bedoelde behoefte en kies hierboven.</p>}
      <label className="field"><span>Toegankelijkheidswens kind {index + 1} (optioneel)</span><input maxLength={500} value={child.accessibilityNote} onChange={event => update(child.key, { accessibilityNote: event.target.value })} /></label>
    </div>)}
    {!children.length && <p className="form-warning">Een inschrijving houdt minstens één deelnemend kind. Voor het laatste kind is een expliciete annulering nodig.</p>}
    <button className="btn outline" type="button" onClick={() => setChildren([...children, blankChild()])}><Plus aria-hidden="true" />Kind toevoegen</button>
  </fieldset>;
}
function GroupDetails({ group, heading }: { group: ManagedRegistrationGroup | null | undefined; heading: string }) {
  return <section className="registration-manage-group"><p className="kicker">{heading}</p><strong>{groupLabel(group)}</strong>{group && <>
    <span>{group.children} gereserveerde kinderen{typeof group.maxChildren === "number" ? ` · maximum ${group.maxChildren}` : ""}</span>
    {group.compositionConfirmed && <span>Groepssamenstelling bevestigd</span>}
    <span>{group.started ? "Groep al begonnen" : group.startConfirmed ? "Startafspraak bevestigd" : "Startafspraak nog niet bevestigd"}</span>
    <span>{group.startPointCode || "Startpunt volgt"} · {time(group.startsAt)}</span>
    {group.desiredEndAt && <span>Gewenst klaar {time(group.desiredEndAt)}</span>}{group.expectedCompletionAt && <span>Verwacht klaar {time(group.expectedCompletionAt)}</span>}
  </>}</section>;
}

export function RegistrationAdministrationStatus({ registration }: { registration: AdminRegistration }) {
  const counts = [
    ["Gereserveerd", registration.reservedChildCount], ["Geactiveerd", registration.activatedChildCount],
    ["Aanwezig", registration.presentChildCount], ["Betaald/vrijgesteld", registration.paidChildCount],
  ] as const;
  return <div className="registration-administration-status">
    <span className="registration-activation-label">{registrationActivationLabel(registration)}</span><span>Mail: {registration.mailStatus ? registrationMailStatus[registration.mailStatus] ?? "Verzendstatus wordt gecontroleerd" : "Geen mailopdracht vastgelegd"}</span>
    <div>{counts.map(([label, value]) => <span key={label}>{label}: <b>{typeof value === "number" ? value : "nog niet vastgesteld"}</b></span>)}</div>
  </div>;
}

export function AdminRegistrationCreateButton({ eventSlug, capabilities, onSaved, onExisting }: { eventSlug: string; capabilities: string[]; onSaved: Saved; onExisting: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  if (!capabilities.some(capability => ["event_admin", "registration_manage"].includes(capability))) return null;
  return <><button className="btn" type="button" onClick={() => setOpen(true)}><Plus aria-hidden="true" />Inschrijving toevoegen</button>{open && <CreateDialog eventSlug={eventSlug} onClose={() => setOpen(false)} onSaved={onSaved} onExisting={id => { setOpen(false); onExisting(id); }} />}</>;
}
function CreateDialog({ eventSlug, onClose, onSaved, onExisting }: { eventSlug: string; onClose: () => void; onSaved: Saved; onExisting: (id: string) => void }) {
  const [options, setOptions] = useState<RegistrationCreationOptions | null>(null);
  const [parentName, setParentName] = useState(""), [email, setEmail] = useState(""), [phone, setPhone] = useState("");
  const [start, setStart] = useState(""), [end, setEnd] = useState(""), [groupId, setGroupId] = useState(""), [partyId, setPartyId] = useState("");
  const [children, setChildren] = useState<RegistrationChildDraft[]>(() => [blankChild()]);
  const [reason, setReason] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState(""), [existingId, setExistingId] = useState<string | null>(null);
  const saving = useRef(false), commandId = useCommandId();
  useEffect(() => { let alive = true; void rpc<RegistrationCreationOptions>("admin_registration_creation_options", { _event_slug: eventSlug }).then(value => { if (alive) setOptions(value); }).catch(failure => { if (alive) setError(safeError(failure)); }); return () => { alive = false; }; }, [eventSlug]);
  async function refreshOptions() {
    if (saving.current) return;
    setError("");
    try { setOptions(await rpc<RegistrationCreationOptions>("admin_registration_creation_options", { _event_slug: eventSlug })); } catch (failure) { setError(safeError(failure)); }
  }
  const selectedGroup = options?.groups.find(group => group.id === groupId), party = options?.parties.find(item => item.id === partyId);
  async function save() {
    if (saving.current || !options) return;
    const validated = registrationChildrenInput(children);
    if (validated.error || !validated.children) return setError(validated.error!);
    if (parentName.trim().length < 2 || !email.trim() || reason.trim().length < 10) return setError("Vul de oudernaam, het e-mailadres en een korte beheerreden in.");
    const payload = { parentName: parentName.trim(), email: email.trim().toLowerCase(), phone: phone.trim() || null, preferredStartAt: start || null, desiredEndAt: end || null,
      children: validated.children.map(child => ({ name: child.firstName, age: child.ageAtEvent, accessibilityNote: child.accessibilityNote, stepFreeRequired: child.stepFreeRequired })), groupId: groupId || null, partyId: partyId || null };
    const request = { _event_slug: eventSlug, _payload: payload, _expected_event_version: options.eventVersion, _reason: reason.trim() };
    saving.current = true; setBusy(true); setError(""); setExistingId(null);
    try {
      const result = await rpc<{ registrationId: string; duplicate?: boolean; existing?: boolean; existingRegistrationId?: string }>("admin_registration_create", { ...request, _command_id: commandId(request) });
      if (result.duplicate || result.existing) { setExistingId(result.existingRegistrationId ?? result.registrationId); await onSaved(); }
      else { await onSaved(); onClose(); }
    } catch (failure) { setError(safeError(failure)); } finally { saving.current = false; setBusy(false); }
  }
  return <ManagementDialog title="Inschrijving toevoegen" description="Eén ouder en alle kinderen vormen samen één gezinsinschrijving. Publieke inschrijvingen blijven gesloten." busy={busy} onClose={onClose}>
    <form onSubmit={event => { event.preventDefault(); void save(); }} className="registration-manage-form">
      {!options && !error && <p role="status">Actuele voorkeuren en groepsruimte ophalen…</p>}
      <fieldset disabled={busy || !options} className="registration-manage-fields"><legend>Ouder</legend>
        <label className="field"><span>Naam ouder</span><input required minLength={2} maxLength={120} autoComplete="name" value={parentName} onChange={event => setParentName(event.target.value)} /></label>
        <div className="two-fields"><label className="field"><span>E-mailadres ouder</span><input required type="email" autoComplete="email" value={email} onChange={event => { setEmail(event.target.value); setExistingId(null); }} /></label><label className="field"><span>Telefoonnummer (optioneel)</span><input type="tel" minLength={6} maxLength={32} autoComplete="tel" value={phone} onChange={event => setPhone(event.target.value)} /></label></div>
        <div className="two-fields"><label className="field"><span>Gewenste starttijd</span><select value={start} onChange={event => setStart(event.target.value)}><option value="">Maakt niet uit</option>{(options?.allowedStartTimes ?? []).map(value => <option key={value} value={value}>{time(value)}</option>)}</select></label><label className="field"><span>Gewenst klaar, inclusief finale</span><select required={Boolean(options?.allowedEndTimes.length)} value={end} onChange={event => setEnd(event.target.value)}><option value="">Kies een tijd</option>{(options?.allowedEndTimes ?? []).map(value => <option key={value} value={value}>{time(value)}</option>)}</select></label></div>
      </fieldset>
      <ChildrenFields drafts={children} setChildren={setChildren} busy={busy || !options} />
      {options && options.canManageGroups !== true && <p className="form-notice">Je kunt de ouder en kinderen zonder groepsindeling aanmelden. Voor het kiezen van een loopgroep of samenloop is daarnaast groepsbeheerbevoegdheid nodig.</p>}
      <fieldset disabled={busy || !options || options.canManageGroups !== true} className="registration-manage-fields"><legend>Indeling</legend>
        <label className="field"><span>Samenloop (optioneel)</span><select value={partyId} onChange={event => { const id = event.target.value; setPartyId(id); const selected = options?.parties.find(item => item.id === id); if (selected?.groupId) setGroupId(selected.groupId); }}><option value="">Zelfstandig gezin</option>{(options?.parties ?? []).map(item => <option key={item.id} value={item.id}>{item.reference} · {item.households} gezinnen · {item.children} kinderen</option>)}</select><small>Een samenloop verbindt gezinnen; deze inschrijving blijft één afzonderlijk gezin.</small></label>
        <label className="field"><span>Loopgroep (optioneel)</span><select value={groupId} disabled={Boolean(party?.groupId)} onChange={event => setGroupId(event.target.value)}><option value="">Nog niet indelen</option>{(options?.groups ?? []).map(group => <option key={group.id} value={group.id} disabled={group.started}>{groupLabel(group)} · {group.children} kinderen{group.startConfirmed ? " · start bevestigd" : " · concept"}{group.started ? " · begonnen" : ""}</option>)}</select></label>
        <GroupDetails group={selectedGroup} heading="Gekozen loopgroep" />
      </fieldset>
      <section className="registration-manage-impact" aria-label="Controle voor aanmaken"><strong>Controle voor opslaan</strong><p>{parentName || "De ouder"} met {children.length} {children.length === 1 ? "kind" : "kinderen"}: {children.map(child => child.name || "naam nog invullen").join(", ") || "nog geen kind"}.</p><p>{selectedGroup ? "De toegewezen kinderen reserveren meteen groepsruimte, ook zolang de ouder nog niet heeft ingelogd." : "Nog geen groep gekozen; er is nog geen bevestigde startafspraak voor dit gezin."}</p><p>Na opslaan wordt één activatiemail verstuurd naar {email || "het ingevulde e-mailadres"}. De inschrijving wacht daarna op de eerste juiste inlog. De bijdrage is apart van activatie{typeof options?.priceCents === "number" ? `: ${money(options.priceCents * children.length)}` : ""}.</p></section>
      <label className="field"><span>Reden voor deze beheerhandeling</span><textarea required minLength={10} maxLength={500} value={reason} disabled={busy} onChange={event => setReason(event.target.value)} /></label>
      <Notice message={error} error />{error && <button className="text-link" type="button" disabled={busy} onClick={() => void refreshOptions()}><RefreshCw aria-hidden="true" />Actuele voorkeuren en groepsruimte ophalen; invoer behouden</button>}{existingId && <div className="form-notice" role="status"><p>Deze ouder heeft al een inschrijving voor dit evenement. Er is geen tweede gezin aangemaakt en geen nieuwe activatiemail verstuurd.</p><button className="btn outline" type="button" onClick={() => onExisting(existingId)}>Bestaande inschrijving bekijken en bewerken</button></div>}
      <div className="registration-manage-footer"><button className="btn outline" type="button" disabled={busy} onClick={onClose}>Annuleren</button><button className="btn" type="submit" disabled={busy || !options || Boolean(existingId)}>{busy ? "Inschrijving opslaan…" : "Inschrijving aanmaken en activatiemail versturen"}</button></div>
    </form>
  </ManagementDialog>;
}

export function AdminRegistrationActions({ eventSlug, registration, capabilities, onSaved }: { eventSlug: string; registration: AdminRegistration; capabilities: string[]; onSaved: Saved }) {
  const [action, setAction] = useState<Action | null>(null);
  const canEdit = capabilities.some(capability => ["event_admin", "registration_manage"].includes(capability));
  const canMove = capabilities.includes("event_admin") || (capabilities.includes("registration_manage") && capabilities.includes("groups_manage"));
  if (!canEdit) return null;
  return <div className="registration-admin-actions">
    <div className="actions"><button className="btn outline" type="button" onClick={() => setAction("edit")}><Pencil aria-hidden="true" />Inschrijving bewerken</button>{canMove && <button className="btn outline" type="button" onClick={() => setAction("move")}><ArrowRightLeft aria-hidden="true" />Verplaatsen naar andere groep</button>}
      {registration.activation?.status === "pending" && <><button className="btn outline" type="button" onClick={() => setAction("resend")}><Mail aria-hidden="true" />Uitnodiging opnieuw versturen</button><button className="text-link" type="button" onClick={() => setAction("email")}>E-mailadres corrigeren vóór activatie</button></>}
    </div>
    {action && (action === "resend" || action === "email" ? <InvitationDialog eventSlug={eventSlug} registration={registration} correction={action === "email"} onClose={() => setAction(null)} onSaved={onSaved} /> : <EditMoveDialog eventSlug={eventSlug} registration={registration} action={action} onClose={() => setAction(null)} onSaved={onSaved} />)}
  </div>;
}
function InvitationDialog({ eventSlug, registration, correction, onClose, onSaved }: { eventSlug: string; registration: AdminRegistration; correction: boolean; onClose: () => void; onSaved: Saved }) {
  const [current, setCurrent] = useState(registration);
  const [email, setEmail] = useState(registration.activation?.email || registration.parentEmail), [reason, setReason] = useState(""), [error, setError] = useState(""), [busy, setBusy] = useState(false);
  const saving = useRef(false), commandId = useCommandId();
  async function save() {
    if (saving.current || typeof current.version !== "number") return;
    if (reason.trim().length < 10) return setError("Beschrijf de beheerreden in minstens 10 tekens.");
    const request = { _event_slug: eventSlug, _registration_id: registration.id, _expected_registration_version: current.version, _email: correction ? email.trim().toLowerCase() : null, _reason: reason.trim() };
    saving.current = true; setBusy(true); setError("");
    try { await rpc("admin_registration_invite", { ...request, _command_id: commandId(request) }); await onSaved(); onClose(); } catch (failure) { setError(safeError(failure)); } finally { saving.current = false; setBusy(false); }
  }
  async function refreshInvitation() {
    if (saving.current) return;
    setError("");
    try {
      const rows = await rpc<AdminRegistration[]>("admin_registrations_snapshot", { _event_slug: eventSlug });
      const value = rows.find(row => row.id === registration.id);
      if (!value) throw new Error("REGISTRATION_NOT_FOUND");
      setCurrent(value);
      if (!correction) setEmail(value.activation?.email || value.parentEmail);
    } catch (failure) { setError(safeError(failure)); }
  }
  return <ManagementDialog title={correction ? "E-mailadres corrigeren" : "Uitnodiging opnieuw versturen"} description={`${registration.parentName} · ${registration.reference}. Alleen een nog niet geactiveerde uitnodiging kan hier worden aangepast.`} busy={busy} onClose={onClose}>
    <form className="registration-manage-form" onSubmit={event => { event.preventDefault(); void save(); }}><label className="field"><span>{correction ? "Gecorrigeerd e-mailadres ouder" : "E-mailadres ouder"}</span><input required type="email" value={email} readOnly={!correction} disabled={busy} onChange={event => setEmail(event.target.value)} /></label>
      <p className="registration-manage-impact">De bestaande uitnodigingslink wordt ingetrokken. Een nieuwe activatiemail gaat alleen naar {email || "het ingevulde adres"}. De opgeslagen inschrijving en kinderen blijven behouden; het oude adres krijgt met de ingetrokken link geen toegang.</p>
      <label className="field"><span>Reden voor deze beheerhandeling</span><textarea required minLength={10} maxLength={500} value={reason} disabled={busy} onChange={event => setReason(event.target.value)} /></label><Notice message={error} error />
      {error && <button className="text-link" type="button" disabled={busy} onClick={() => void refreshInvitation()}><RefreshCw aria-hidden="true" />Actuele uitnodiging ophalen; correctie behouden</button>}
      {current.activation?.status !== "pending" && <Notice message="Deze inschrijving is inmiddels geactiveerd. Gebruik voor e-mailwijzigingen de veilige accountprocedure." error />}
      {typeof current.version !== "number" && <Notice message="De actuele inschrijvingsversie ontbreekt. Vernieuw het overzicht voordat je een uitnodiging verstuurt." error />}
      <div className="registration-manage-footer"><button className="btn outline" type="button" disabled={busy} onClick={onClose}>Annuleren</button><button className="btn" type="submit" disabled={busy || typeof current.version !== "number" || current.activation?.status !== "pending"}>{busy ? "Uitnodiging opslaan…" : correction ? "E-mailadres aanpassen en nieuwe uitnodiging versturen" : "Nieuwe uitnodiging versturen"}</button></div>
    </form>
  </ManagementDialog>;
}
function EditMoveDialog({ eventSlug, registration, action, onClose, onSaved }: { eventSlug: string; registration: AdminRegistration; action: "edit" | "move"; onClose: () => void; onSaved: Saved }) {
  const [preview, setPreview] = useState<RegistrationManagementPreview | null>(null), [children, setChildren] = useState<RegistrationChildDraft[]>([]);
  const [targetId, setTargetId] = useState(""), [reason, setReason] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState(""), [loading, setLoading] = useState(true);
  const saving = useRef(false), commandId = useCommandId();
  useEffect(() => { let alive = true; void rpc<RegistrationManagementPreview>("admin_registration_management_preview", { _event_slug: eventSlug, _registration_id: registration.id }).then(value => {
    if (!alive) return; setPreview(value); setTargetId(value.sourceGroup?.id ?? "");
    setChildren(value.children.filter(child => child.participationStatus === "active").map(child => ({ key: child.id, id: child.id, name: child.firstName, age: child.ageAtEvent === null ? "" : String(child.ageAtEvent), accessibilityNote: child.accessibilityNote ?? "", stepFreeRequired: child.stepFreeRequired ?? (child.accessibilityNote?.trim()?null:false) })));
  }).catch(failure => { if (alive) setError(safeError(failure)); }).finally(() => { if (alive) setLoading(false); }); return () => { alive = false; }; }, [eventSlug, registration.id]);
  async function refreshVersion() {
    if (saving.current) return;
    setLoading(true); setError("");
    try { setPreview(await rpc<RegistrationManagementPreview>("admin_registration_management_preview", { _event_slug: eventSlug, _registration_id: registration.id })); } catch (failure) { setError(safeError(failure)); } finally { setLoading(false); }
  }
  const target = preview?.groups.find(group => group.id === targetId), changes = registrationChildChanges(preview?.children ?? [], children);
  const allowed = Boolean(preview && (action === "edit" ? preview.canEdit : preview.canMove));
  const sameGroup = action === "move" && Boolean(targetId && targetId === preview?.sourceGroup?.id);
  async function save() {
    if (saving.current || !preview || !allowed) return;
    if (reason.trim().length < 10) return setError("Beschrijf de beheerreden in minstens 10 tekens.");
    const validated = action === "edit" ? registrationChildrenInput(children) : null;
    if (validated?.error) return setError(validated.error);
    if (action === "move" && !targetId) return setError("Kies de nieuwe loopgroep voor deze volledige inschrijving.");
    const request = { _event_slug: eventSlug, _registration_id: registration.id, _action: action === "edit" ? "edit_children" : "move", _payload: action === "edit" ? { children: validated!.children } : { targetGroupId: targetId }, _input_hash: preview.inputHash, _reason: reason.trim() };
    saving.current = true; setBusy(true); setError("");
    try { await rpc("admin_registration_manage_apply", { ...request, _idempotency_key: commandId(request) }); await onSaved(); onClose(); } catch (failure) { setError(safeError(failure)); } finally { saving.current = false; setBusy(false); }
  }
  return <ManagementDialog title={action === "edit" ? "Inschrijving bewerken" : "Verplaatsen naar andere groep"} description={`${registration.parentName} · ${registration.reference}. Eén gezinsinschrijving blijft één geheel.`} busy={busy} onClose={onClose}>
    <form className="registration-manage-form" onSubmit={event => { event.preventDefault(); void save(); }}>
      {loading && <p role="status">Actuele deelnemers en groepsruimte ophalen…</p>}
      {preview && !allowed && <p className="form-warning" role="alert">Je hebt geen bevoegdheid voor deze actie, of deze inschrijving vraagt de bestaande overdrachtsprocedure.</p>}
      {action === "edit" && preview && <><p className="registration-manage-impact">Ouder: {registration.parentName} · {registration.parentEmail}{registration.phone ? ` · ${registration.phone}` : ""}. Accountgegevens blijven bij het ouderaccount; hieronder bewerk je de kindgegevens en deelname.</p><p>{registration.activation?.status === "pending" ? "Ook toegevoegde kinderen blijven onder dezelfde uitnodiging vallen." : "De ouder en bestaande kinderen hoeven niet opnieuw te activeren."} De huidige groep en samenloop blijven gekoppeld.</p><ChildrenFields drafts={children} setChildren={setChildren} busy={busy || loading || !allowed} />{preview.children.some(child => child.participationStatus !== "active") && <details><summary>Eerder verwijderde deelnames</summary><ul>{preview.children.filter(child => child.participationStatus !== "active").map(child => <li key={child.id}>{child.firstName} · deelname verwijderd; historie blijft bewaard</li>)}</ul></details>}<section className="registration-manage-impact" aria-label="Controle voor bewerken"><strong>Na opslaan: {changes.after} deelnemende {changes.after === 1 ? "kind" : "kinderen"} (nu {changes.before})</strong>{changes.added.length > 0 && <p>Toegevoegd: {changes.added.join(", ")}.</p>}{changes.corrected.length > 0 && <p>Gegevens gecorrigeerd: {changes.corrected.join(", ")}.</p>}{changes.removed.length > 0 && <p>Deelname verwijderd: {changes.removed.join(", ")}. De kindidentiteit, het paspoort en de betaalhistorie blijven behouden.</p>}<p>Bedragen en toekomstige bezetting worden volgens de bestaande regels bijgewerkt. Er wordt geen betaling of terugbetaling uitgevoerd en geen groepsmail verstuurd.</p></section><GroupDetails group={preview.sourceGroup} heading="Deze loopgroep blijft behouden" /></>}
      {action === "move" && preview && <><div className="registration-manage-groups"><GroupDetails group={preview.sourceGroup} heading="Van loopgroep" /><GroupDetails group={target} heading="Naar loopgroep" /></div><label className="field"><span>Nieuwe loopgroep</span><select required value={targetId} disabled={busy || loading || !allowed} onChange={event => setTargetId(event.target.value)}><option value="">Kies een groep</option>{preview.groups.map(group => <option key={group.id} value={group.id} disabled={group.started}>{groupLabel(group)} · {group.children} kinderen{group.startConfirmed ? " · start bevestigd" : " · concept"}{group.started ? " · begonnen" : ""}</option>)}</select></label>
        <section className="registration-manage-impact" aria-label="Controle voor verplaatsen"><strong>{sameGroup ? "Dezelfde groep: er verandert niets" : "Alleen dit gezin verplaatsen"}</strong><p>{sameGroup ? "Dezelfde groep kiezen wijzigt geen indeling, revisie of mail." : `Deze inschrijving met ${preview.children.filter(child => child.participationStatus === "active").length} kinderen verhuist van ${groupLabel(preview.sourceGroup)} naar ${groupLabel(target)}. Alleen deze ouder ontvangt een wijzigingsmail.`}</p>{preview.together.otherHouseholds > 0 && !sameGroup && <p>Dit gezin komt los van {preview.together.otherHouseholds} andere {preview.together.otherHouseholds === 1 ? "gezinsinschrijving" : "gezinsinschrijvingen"} in de samenloop. Die gezinnen worden niet meeverplaatst.</p>}{target && !sameGroup && <p>{target.startConfirmed ? `De bevestigde doelafspraak wordt overgenomen: ${target.startPointCode || "bevestigd startpunt"} om ${time(target.startsAt)}.` : "De doelgroep heeft nog geen bevestigde startafspraak. Een concepttijd is nog niet definitief."} Het startadres blijft tot het bestaande vrijgavemoment afgeschermd. Andere gezinnen behouden hun startafspraak.</p>}</section>
      </>}
      <label className="field"><span>Reden voor deze beheerhandeling</span><textarea required minLength={10} maxLength={500} value={reason} disabled={busy || loading} onChange={event => setReason(event.target.value)} /></label><Notice message={error} error />
      {error && <button className="text-link" type="button" disabled={busy || loading} onClick={() => void refreshVersion()}><RefreshCw aria-hidden="true" />Actuele versie ophalen; mijn invoer behouden</button>}
      <div className="registration-manage-footer"><button className="btn outline" type="button" disabled={busy} onClick={onClose}>Annuleren</button><button className="btn" type="submit" disabled={busy || loading || !allowed || (action === "move" && !targetId)}>{busy ? "Wijziging opslaan…" : action === "edit" ? "Wijziging van deelname opslaan" : sameGroup ? "Dezelfde groep behouden" : "Inschrijving verplaatsen en ouder mailen"}</button></div>
    </form>
  </ManagementDialog>;
}
