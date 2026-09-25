export type PaymentRegistrationStage = "needs_link" | "link_sent" | "paid";

type PaymentStatusRow = {
  status: string;
};

export function paymentRegistrationStage(rows: PaymentStatusRow[]): PaymentRegistrationStage | null {
  const activeRows = rows.filter((row) => row.status !== "cancelled");
  if (activeRows.length === 0) return null;
  if (activeRows.every((row) => row.status === "confirmed" || row.status === "waived")) return "paid";
  if (activeRows.some((row) => row.status === "awaiting_link")) return "needs_link";
  return "link_sent";
}
