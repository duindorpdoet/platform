import "server-only";

type TemplateInput = { messageType: string; payload: Record<string, unknown> };

const escapeHtml = (value: unknown) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]!);

export function renderTransactionalMail({ messageType, payload }: TemplateInput) {
  const reference = escapeHtml(payload.reference ?? payload.registrationReference ?? payload.applicationReference ?? payload.ticketReference ?? "");
  const context = payload.subject ? `Onderwerp: ${escapeHtml(payload.subject)}` : "";
  const siteUrl = /^https?:\/\//.test(process.env.NEXT_PUBLIC_SITE_URL ?? "") ? escapeHtml(process.env.NEXT_PUBLIC_SITE_URL) : "";
  const definitions: Record<string, { subject: string; heading: string; body: string }> = {
    registration_received: { subject: "Inschrijving ontvangen", heading: "Je inschrijving staat klaar", body: "We hebben je inschrijving ontvangen. Betaling en groepsindeling worden afzonderlijk bevestigd." },
    portal_received: { subject: "Aanmelding van je huis ontvangen", heading: "Je poortaanmelding is ontvangen", body: "De organisatie beoordeelt je aanmelding. Een inzending is nog geen definitieve deelname." },
    contact_received: { subject: "Je bericht is ontvangen", heading: "Bedankt voor je bericht", body: "De organisatie neemt contact op zodra dat kan." },
    sponsor_received: { subject: "Sponsorvoorstel ontvangen", heading: "Bedankt voor je voorstel", body: "We beoordelen je voorstel en nemen contact op." },
    payment_reported: { subject: "Betaling gemeld", heading: "Je betaalmelding is ontvangen", body: "De organisatie controleert de betaling handmatig. Dit is nog geen betalingsbevestiging." },
  };
  const content = definitions[messageType] ?? { subject: "Update over Halloween in Duindorp", heading: "Er is een update", body: "Bekijk je persoonlijke omgeving voor de actuele informatie." };
  const text = `${content.heading}\n\n${content.body}${context ? `\n\n${context}` : ""}${reference ? `\n\nReferentie: ${reference}` : ""}${siteUrl ? `\n\n${siteUrl}` : ""}\n\nDe Duindorpse Poorten van Halloween`;
  const html = `<!doctype html><html lang="nl"><body style="margin:0;background:#060b13;color:#eee9de;font:16px Arial,sans-serif"><div style="max-width:620px;margin:auto;padding:40px 24px"><p style="color:#dfa777;text-transform:uppercase;letter-spacing:.12em">31 oktober 2026 · Duindorp</p><h1 style="font:36px Georgia,serif">${escapeHtml(content.heading)}</h1><p style="line-height:1.7;color:#bcc7d2">${escapeHtml(content.body)}</p>${context ? `<p>${context}</p>` : ""}${reference ? `<p style="padding:16px;border:1px solid #283344">Referentie: <strong>${reference}</strong></p>` : ""}${siteUrl ? `<p><a href="${siteUrl}" style="color:#dfa777">Open de beveiligde omgeving</a></p>` : ""}<p style="margin-top:32px;color:#8e9baa;font-size:13px">De Duindorpse Poorten van Halloween</p></div></body></html>`;
  return { subject: content.subject, text, html };
}
