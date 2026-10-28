import { describe, expect, it } from "vitest";
import { contactPersonName, conversationIdentityLabel, messengerSenderLabel, usablePersonName, walkingGroupLabel } from "./contact-identity";

describe("separate person, household and walking-group identity", () => {
  it("shows the complete registered name before additional group context", () => {
    expect(conversationIdentityLabel({ personName: "Zoë van den Berg", groupCode: "G-28" })).toBe("Zoë van den Berg · G-28");
  });
  it.each(["G-28", "G-02", "G-11"])("does not turn repeated legacy %s group fields into a person", code => {
    const legacy = { subjectKind: "group", systemCode: code, displayName: code, subjectLabel: `${code} · ${code}` };
    expect(conversationIdentityLabel(legacy)).toBe(`Deelnemer · ${code}`);
    expect(conversationIdentityLabel({ ...legacy, personName: "Élodie van 't Hof", groupCode: code })).toBe(`Élodie van 't Hof · ${code}`);
  });
  it("keeps household labels and custom walking-group names out of the contact-name fallback", () => {
    expect(contactPersonName({ householdLabel: "Familie van Dijk", groupName: "Nachtlopers", groupCode: "G-46" })).toBe("Deelnemer");
    expect(contactPersonName({ parentName: "G-46", personName: "G-46" })).toBe("Deelnemer");
    expect(usablePersonName("ouder@example.invalid")).toBeNull();
  });
  it("preserves accents, spelling and surname particles", () => {
    expect(contactPersonName({ personName: "  Élodie van 't Hof-de Peña  " })).toBe("Élodie van 't Hof-de Peña");
    expect(contactPersonName({ parentName: "Daniël de la Cruz" })).toBe("Daniël de la Cruz");
  });
  it("uses current group context after a move/reload without changing the person or conversation identity", () => {
    const conversation = { id: "conversation-1", personName: "Zoë van den Berg", groupCode: "G-28" };
    const reloaded = { ...conversation, groupCode: "G-46" };
    expect(conversationIdentityLabel(reloaded)).toBe("Zoë van den Berg · G-46");
    expect(reloaded.id).toBe(conversation.id);
    expect(conversationIdentityLabel(conversation)).toBe("Zoë van den Berg · G-28");
  });
  it("keeps different people and senders separate when their names are identical", () => {
    const contacts = [{ id: "person-1", personName: "Sam de Jong", groupCode: "G-02" }, { id: "person-2", personName: "Sam de Jong", groupCode: "G-02" }];
    expect(new Map(contacts.map(contact => [contact.id, conversationIdentityLabel(contact)])).size).toBe(2);
    expect(messengerSenderLabel({ senderSide: "participant", senderName: "Sam de Jong" })).toBe("Sam de Jong");
    expect(messengerSenderLabel({ senderSide: "participant", senderName: "G-02" })).toBe("Deelnemer");
    expect(messengerSenderLabel({ senderSide: "organization", senderName: "G-02" })).toBe("Organisatie");
  });
  it("displays each group code once while retaining a real custom group name", () => {
    expect(walkingGroupLabel({ groupCode: "G-46", groupName: "G-46" })).toBe("G-46");
    expect(walkingGroupLabel({ groupCode: "G-46", groupName: "De Nachtdwalers" })).toBe("G-46 · De Nachtdwalers");
  });
});
