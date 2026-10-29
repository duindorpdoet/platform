import { describe, expect, it } from "vitest";
import { registrationActivationLabel, registrationAdminError, registrationChildChanges, registrationChildrenInput, type ManagedRegistrationChild, type RegistrationChildDraft } from "./admin-registrations";
const draft = (values: Partial<RegistrationChildDraft> = {}): RegistrationChildDraft => ({ key: "local-row", id: "registration-child-a", name: "  Noor  ", age: "7", accessibilityNote: "", ...values });
const child = (values: Partial<ManagedRegistrationChild> = {}): ManagedRegistrationChild => ({ id: "registration-child-a", childId: "stable-passport-child-a", firstName: "Noor", ageAtEvent: 7, accessibilityNote: null, participationStatus: "active", unitPriceCents: 350, ...values });
describe("organizer registration child commands", () => {
  it("keeps the registration-child identity through a correction and sends no client child identity", () => {
    expect(registrationChildrenInput([draft({ name: "  Nora ", accessibilityNote: "  rustig tempo  " })]).children).toEqual([{ id: "registration-child-a", firstName: "Nora", ageAtEvent: 7, accessibilityNote: "rustig tempo" }]);
  });
  it("never infers a route requirement from free text and preserves an explicit review decision", () => {
    const note = "  rustige ontvangst graag  ";
    expect(registrationChildrenInput([draft({ accessibilityNote: note })]).children?.[0]).not.toHaveProperty("stepFreeRequired");
    for (const choice of [true, false, null]) {
      const input = registrationChildrenInput([draft({ accessibilityNote: note, stepFreeRequired: choice })]).children![0];
      expect(input.stepFreeRequired).toBe(choice);
      expect(input.accessibilityNote).toBe(note.trim());
    }
    expect(registrationChildChanges([child({ accessibilityNote: note.trim(), stepFreeRequired: null })], [draft({ accessibilityNote: note, stepFreeRequired: false })]).corrected).toEqual(["Noor"]);
  });
  it("accepts both existing age boundaries and an additional child under the same command", () => {
    expect(registrationChildrenInput([draft({ age: "0" }), draft({ key: "new-row", id: null, age: "20", name: "Sam" })]).children).toHaveLength(2);
  });
  it.each(["-1", "21", "7.5", "", "abc"])("rejects invalid age %s without replacing the draft", age => {
    const value = draft({ age });
    expect(registrationChildrenInput([value]).error).toMatch(/leeftijd/);
    expect(value.age).toBe(age);
  });
  it("requires a deliberate cancellation for the last child and rejects a repeated identity", () => {
    expect(registrationChildrenInput([]).error).toMatch(/expliciete annulering/);
    expect(registrationChildrenInput([draft(), draft({ key: "another-row" })]).error).toMatch(/twee keer/);
  });
  it("describes corrections, new participants and soft removals while excluding old cancelled participation", () => {
    const existing = [child(), child({ id: "registration-child-b", firstName: "Bo" }), child({ id: "old-row", participationStatus: "cancelled", firstName: "Historie" })];
    const before = structuredClone(existing);
    expect(registrationChildChanges(existing, [draft({ name: "Nora" }), draft({ key: "new", id: null, name: "Sam" })])).toEqual({ before: 2, after: 2, added: ["Sam"], removed: ["Bo"], corrected: ["Nora"] });
    expect(existing).toEqual(before);
  });
  it("shows actual needed and available capacity without exposing raw database details", () => {
    const message = registrationAdminError({ message: "GROUP_CAPACITY_EXCEEDED", details: JSON.stringify({ needed: 14, available: 12, privateName: "MUST_NOT_LEAK" }) });
    expect(message).toContain("Benodigd: 14; beschikbaar: 12");
    expect(message).not.toContain("MUST_NOT_LEAK");
  });
  it("keeps activation independent of financial or attendance assumptions", () => {
    expect(registrationActivationLabel({ activation: { status: "pending" } })).toBe("Wacht op eerste inlog");
    expect(registrationActivationLabel({ activation: { status: "activated" } })).toBe("Geactiveerd · definitief");
    expect(registrationActivationLabel({})).toContain("niet beschikbaar");
  });
});
