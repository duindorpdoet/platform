import { z } from "zod";

const count = z.number().int().nonnegative();
const message = z.object({ subject: z.string().min(1), body: z.string().min(1) });
const snapshotSchema = z.object({
  event: z.object({ id: z.string().min(1), slug: z.string().min(1), title: z.string() }),
  ready: z.boolean(), confirmed: z.boolean(),
  campaign: message.extend({ id: z.string().min(1), createdAt: z.string().refine(value => Number.isFinite(Date.parse(value))), createdBy: z.string().min(1) }).nullable(),
  message: message.nullable(),
  counts: z.object({ participatingHouses: count, teamAccounts: count, uniqueEmailRecipients: count, missingContactAccounts: count }),
  mail: z.object({ pending: count, queued: count, processed: count, providerAccepted: count, delivered: count, failed: count, unknown: count, suppressed: count, retryableFailed: count }),
  existing: z.boolean().optional(), requeued: count.optional(),
}).refine(value => value.confirmed ? Boolean(value.campaign && value.message && value.campaign.subject === value.message.subject && value.campaign.body === value.message.body) : value.campaign === null && value.message === null);

export type PortalCertificateSnapshot = z.infer<typeof snapshotSchema>;
export type PortalCertificateMail = PortalCertificateSnapshot["mail"];
export function validatePortalCertificateSnapshot(value: unknown, eventSlug: string, eventId: string): PortalCertificateSnapshot | null {
  const parsed = snapshotSchema.safeParse(value);
  return parsed.success && parsed.data.event.slug === eventSlug && parsed.data.event.id === eventId ? parsed.data : null;
}
