import React from "react";
import { createRoot } from "react-dom/client";
import { ParticipantUpdates } from "../../components/admin/participant-updates";
import css from "../../app/globals.css?raw";

const edition = new URLSearchParams(location.search).get("event");
const eventSlug = edition === "2026" ? "duindorp-halloween-2026" : edition === "2027" ? "frightnight-2027-test" : "updates-component-test";

createRoot(document.getElementById("root")!).render(<React.StrictMode>
  <style>{css.replace(/^@import[^;]+;/gm, "")}</style>
  <main className="modern-ui" style={{ maxWidth: 960, padding: 16, margin: "auto" }}><ParticipantUpdates eventSlug={eventSlug} /></main>
</React.StrictMode>);
