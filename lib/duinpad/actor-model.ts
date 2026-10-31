export const ACTOR_PERMISSIONS = ['heks.ready', 'heks.go', 'zone1.trigger', 'zone2.trigger', 'zone3.trigger', 'finale.ready', 'finale.go', 'zone1.stop', 'zone2.stop', 'zone3.stop', 'stop-all'] as const;
export type ActorPermission = typeof ACTOR_PERMISSIONS[number];
export const ACTOR_LABELS: Record<ActorPermission, string> = {
  'heks.ready': 'Heks gereed', 'heks.go': 'Heks GO', 'zone1.trigger': 'Zone 1 starten', 'zone2.trigger': 'Zone 2 starten', 'zone3.trigger': 'Zone 3 starten',
  'finale.ready': 'Finale gereed', 'finale.go': 'Finale GO', 'zone1.stop': 'Zone 1 stoppen', 'zone2.stop': 'Zone 2 stoppen', 'zone3.stop': 'Zone 3 stoppen', 'stop-all': 'ALLES STOPPEN',
};
export type ActorControl = { action: ActorPermission; enabled: boolean; blocked_reason: string | null; group_id: string | null; effect: { active: boolean; remaining: number } | null };
export type ActorReceipt = { commandId: string; action: ActorPermission; status: string; result: { ok?: boolean; message?: string; unknown?: boolean }; createdAt?: string };
export type ActorSnapshot = { name: string; revision: number; permissions: ActorPermission[]; connected: boolean; compatible: boolean; observedAt: number; controls: ActorControl[]; receipts: ActorReceipt[] };
export type ActorAdminRow = { id: string; name: string; email: string; status: 'pending' | 'active' | 'revoked' | 'expired'; permissions: ActorPermission[]; revision: number; lastSeenAt: string | null; activatedAt: string | null; expiresAt: string | null; mailStatus: string | null };
