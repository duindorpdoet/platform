import "server-only";

type TemplateInput = { messageType: string; payload: Record<string, unknown> };

const escapeHtml = (value: unknown) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]!);

export function renderTransactionalMail({ messageType, payload }: TemplateInput) {
  const reference = escapeHtml(payload.reference ?? payload.registrationReference ?? payload.applicationReference ?? payload.ticketReference ?? "");
  const context = payload.subject ? `Onderwerp: ${escapeHtml(payload.subject)}` : "";
  const notificationDetails = [
    payload.contactName ? `Naam: ${String(payload.contactName)}` : "",
    payload.contactEmail ? `E-mail: ${String(payload.contactEmail)}` : "",
    payload.contributionType ? `Bijdrage: ${String(payload.contributionType)}` : "",
    payload.senderLabel ? `Van: ${String(payload.senderLabel)}` : "",
    typeof payload.proposedAmountCents === "number" ? `Voorgesteld bedrag: € ${(payload.proposedAmountCents / 100).toFixed(2)}` : "",
    payload.message ? `Bericht: ${String(payload.message)}` : "",
  ].filter(Boolean);
  const configuredSiteUrl = process.env.APP_URL || process.env.NEXT_PUBLIC_SITE_URL || "";
  const siteUrlRaw = /^https?:\/\//.test(configuredSiteUrl) ? configuredSiteUrl : "";
  const siteUrl = escapeHtml(siteUrlRaw);
  const actionPath = typeof payload.actionPath === "string" && /^\/[A-Za-z0-9/?=&._%-]+$/.test(payload.actionPath) ? payload.actionPath : "";
  const actionUrl = siteUrlRaw && actionPath ? escapeHtml(new URL(actionPath, siteUrlRaw).toString()) : "";
  const definitions: Record<string, { subject: string; heading: string; body: string }> = {
    registration_received: { subject: "Inschrijving ontvangen", heading: "Je inschrijving staat klaar", body: "We hebben je inschrijving ontvangen. Betaling en groepsindeling worden afzonderlijk bevestigd." },
    portal_received: { subject: "Aanmelding van je huis ontvangen", heading: "Je poortaanmelding is ontvangen", body: "De organisatie beoordeelt je aanmelding. Een inzending is nog geen definitieve deelname." },
    contact_received: { subject: "Je bericht is ontvangen", heading: "Bedankt voor je bericht", body: "De organisatie neemt contact op zodra dat kan." },
    sponsor_received: { subject: "Sponsorvoorstel ontvangen", heading: "Bedankt voor je voorstel", body: "We beoordelen je voorstel en nemen contact op." },
    contact_notification: { subject: "Nieuw contactbericht", heading: "Nieuw contactbericht ontvangen", body: "Een bezoeker heeft het openbare contactformulier ingestuurd." },
    sponsor_notification: { subject: "Nieuw sponsorvoorstel", heading: "Nieuw sponsorvoorstel ontvangen", body: "Een bezoeker heeft het openbare sponsorformulier ingestuurd." },
    payment_reported: { subject: "Betaling gemeld", heading: "Je betaalmelding is ontvangen", body: "De organisatie controleert de betaling handmatig. Dit is nog geen betalingsbevestiging." },
    household_invite: { subject: "Uitnodiging voor gezinstoegang", heading: "Je bent uitgenodigd als tweede volwassene", body: "Log in met precies dit e-mailadres en accepteer de eenmalige uitnodiging. Deel de link niet met anderen." },
    group_ticket_message_organization: { subject: "Nieuw bericht bij Hulp & contact", heading: "Er staat een nieuw bericht klaar", body: "Open Hulp & contact in het beheerscherm om het gesprek te lezen en namens de organisatie te reageren." },
    group_ticket_message_leader: { subject: "Nieuw bericht over jouw groep", heading: "Er staat een nieuw bericht klaar", body: "Open Hulp & contact in de deelnemersomgeving om het gesprek te lezen en te reageren." },
    group_viewer_invite: { subject: "Uitnodiging om een groep te volgen", heading: "Je mag veilig meekijken", body: "Deze persoonlijke toegang toont beperkte groepsvoortgang en relevante updates. Kindernamen, live GPS en toekomstige adressen blijven verborgen." },
    participant_update: { subject: String(payload.title ?? "Nieuwe update voor jouw Halloweenavond"), heading: String(payload.title ?? "Er is een nieuwe update"), body: String(payload.message ?? "Open je persoonlijke omgeving voor de actuele informatie.") },
  };
  const content = definitions[messageType] ?? { subject: "Update over Halloween in Duindorp", heading: "Er is een update", body: "Bekijk je persoonlijke omgeving voor de actuele informatie." };
  const destination = actionUrl || siteUrl;
  const detailsText = notificationDetails.length > 0 ? `\n\n${notificationDetails.join("\n")}` : "";
  const detailsHtml = notificationDetails.length > 0 ? `<div style="padding:16px;border:1px solid #283344">${notificationDetails.map((detail) => `<p>${escapeHtml(detail)}</p>`).join("")}</div>` : "";
  const text = `${content.heading}\n\n${content.body}${context ? `\n\n${context}` : ""}${detailsText}${reference ? `\n\nReferentie: ${reference}` : ""}${destination ? `\n\n${destination}` : ""}\n\nDe Duindorpse Poorten van Halloween`;
  const html = `<!doctype html><html lang="nl"><body style="margin:0;background:#060b13;color:#eee9de;font:16px Arial,sans-serif"><div style="max-width:620px;margin:auto;padding:40px 24px"><p style="color:#dfa777;text-transform:uppercase;letter-spacing:.12em">31 oktober 2026 · Duindorp</p><h1 style="font:36px Georgia,serif">${escapeHtml(content.heading)}</h1><p style="line-height:1.7;color:#bcc7d2">${escapeHtml(content.body)}</p>${context ? `<p>${context}</p>` : ""}${detailsHtml}${reference ? `<p style="padding:16px;border:1px solid #283344">Referentie: <strong>${reference}</strong></p>` : ""}${destination ? `<p><a href="${destination}" style="color:#dfa777">Open de beveiligde omgeving</a></p>` : ""}<p style="margin-top:32px;color:#8e9baa;font-size:13px">De Duindorpse Poorten van Halloween</p></div></body></html>`;
  return { subject: content.subject, text, html };
}
