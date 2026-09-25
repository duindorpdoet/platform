import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { ChildPaymentRows, childPaymentFor, childPaymentState, type ChildPaymentBatch, type PaymentChild } from "./child-payment-rows";

vi.mock("@/lib/supabase/client", () => ({ createClient: vi.fn() }));

const batch: ChildPaymentBatch = {
  id: "batch-1", version: 3, totalAmountCents: 500, status: "awaiting_payment",
  childNames: ["Noor", "Sam"], anchorChildId: "child-1", anchorChildName: "Noor",
  externalUrl: "https://tikkie.me/pay/together", canPay: true,
};
const children: PaymentChild[] = [
  { id: "child-1", firstName: "Noor", status: "active", unitPriceCents: 250, payment: { status: "awaiting_payment", version: 1, batch } },
  { id: "child-2", firstName: "Sam", status: "active", unitPriceCents: 250, payment: { status: "awaiting_payment", version: 1, batch } },
  { id: "child-3", firstName: "Robin", status: "active", unitPriceCents: 250, payment: { status: "awaiting_payment", version: 1, batch: { ...batch, id: "batch-2", childNames: ["Robin"], anchorChildId: "child-3", anchorChildName: "Robin", totalAmountCents: 250, externalUrl: "https://tikkie.me/pay/separate" } } },
];
function render(items: PaymentChild[]) {
  return renderToStaticMarkup(createElement(ChildPaymentRows, { items, registrationId: "registration-1", reload: async () => {} }));
}

describe("per-child payment-link actions", () => {
  it("renders one active button per payment link immediately after the anchor child's name", () => {
    const html = render(children);
    expect(html.match(/class="child-tikkie-action" href=/g)).toHaveLength(2);
    expect(html).toMatch(/<strong>Noor<\/strong><a class="child-tikkie-action"/);
    expect(html).toMatch(/<strong>Sam<\/strong><button class="child-tikkie-action"[^>]*disabled/);
    expect(html).toContain("Inbegrepen bij Noor");
    expect(html).toContain("Eén betaling voor Noor · Sam");
    expect(html).toContain("Open betaallink voor Robin:");
    expect(html).not.toContain('class="payment-details"');
  });

  it("matches the anchor against the child identity without replacing the registration-child identity", () => {
    const child = { ...children[0], id: "registration-child-1", childId: "child-1" };
    expect(render([child])).toContain('href="https://tikkie.me/pay/together"');
    expect(render([child])).toContain('data-child-payment-row="registration-child-1"');
  });

  it("keeps a linked non-payer inactive even if a stale payload still contains a URL", () => {
    const child = { ...children[0], payment: { ...children[0].payment!, batch: { ...batch, canPay: false } } };
    const html = render([child]);
    expect(html).not.toContain('href="https://tikkie.me');
    expect(html).not.toContain("Betaling melden");
    expect(html).toContain("Betaallink inbegrepen");
  });

  it.each(["reported", "confirmed", "needs_review", "cancelled"])("does not present a payable link for %s batches", (status) => {
    const child = { ...children[0], payment: { status, version: 2, batch: { ...batch, status } } };
    expect(render([child])).not.toContain('href="https://tikkie.me');
  });

  it("shows a disabled pending action before assignment and hides cancelled children's links", () => {
    const pending = { ...children[0], payment: { status: "awaiting_link", version: 1, batch: null } };
    expect(render([pending])).toContain("Betaallink volgt");
    expect(render([pending])).not.toContain('href="https://tikkie.me');
    expect(render([{ ...children[0], status: "cancelled" }])).toContain("Niet actief");
    expect(render([{ ...children[0], status: "cancelled" }])).not.toContain('href="https://tikkie.me');
  });

  it("uses child payment status for access, independently of siblings", () => {
    expect(childPaymentState(children[0], { status: "confirmed", version: 2, batch: { ...batch, status: "confirmed" } }).paid).toBe(true);
    expect(childPaymentState(children[1], children[1].payment!).paid).toBe(false);
  });

  it("retains a single legacy action until the server provides child payment records", () => {
    const oldChildren = children.map((child) => ({ id: child.id, firstName: child.firstName, status: child.status, unitPriceCents: child.unitPriceCents }));
    const legacy = { status: "awaiting_payment", version: 4, amountCents: 750, externalUrl: "https://tikkie.me/pay/legacy" };
    const first = childPaymentFor(oldChildren[0], oldChildren, legacy);
    expect(first?.batch).toMatchObject({ legacy: true, anchorChildId: "child-1", totalAmountCents: 750 });
    expect(childPaymentState(oldChildren[0], first).canPay).toBe(true);
    expect(childPaymentState(oldChildren[1], childPaymentFor(oldChildren[1], oldChildren, legacy)).canPay).toBe(false);
    expect(childPaymentFor({ ...oldChildren[0], payment: null }, oldChildren, legacy)).toBeNull();
  });
});
