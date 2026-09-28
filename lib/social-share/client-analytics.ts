"use client";

export type CampaignKind = "house_registration" | "participant_registration";
type Campaign = { publicShareId: string; kind: CampaignKind };

const campaignKey = "deelstudio-campaign";

function sessionId() {
  const key = "deelstudio-session";
  let value = sessionStorage.getItem(key);
  if (!value) { value = crypto.randomUUID(); sessionStorage.setItem(key, value); }
  return value;
}
async function event(publicShareId: string, eventType: string) {
  await fetch("/api/deelstudio/events", {
    method: "POST", headers: { "Content-Type": "application/json" }, keepalive: true,
    body: JSON.stringify({ publicShareId, eventType, sessionId: sessionId() }),
  });
}

export function rememberShareCampaign(campaign: Campaign) {
  sessionStorage.setItem(campaignKey, JSON.stringify(campaign));
  void event(campaign.publicShareId, `${campaign.kind}_started`);
}

export function trackShareCampaignCompletion(kind: CampaignKind) {
  try {
    const campaign = JSON.parse(sessionStorage.getItem(campaignKey) ?? "null") as Campaign | null;
    if (!campaign || campaign.kind !== kind) return;
    const completedKey = `${campaignKey}:completed:${campaign.publicShareId}:${kind}`;
    if (sessionStorage.getItem(completedKey)) return;
    sessionStorage.setItem(completedKey, "true");
    void event(campaign.publicShareId, `${kind}_completed`);
  } catch {
    // Analytics never blocks a successful registration.
  }
}
