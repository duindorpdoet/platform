import React from "react";
import { createRoot } from "react-dom/client";
import { ParticipantUpdates } from "../../components/admin/participant-updates";
import css from "../../app/globals.css?raw";

createRoot(document.getElementById("root")!).render(<React.StrictMode>
  <style>{css.replace(/^@import[^;]+;/gm, "")}</style>
  <main className="modern-ui" style={{ maxWidth: 960, padding: 16, margin: "auto" }}><ParticipantUpdates eventSlug="updates-component-test" /></main>
</React.StrictMode>);
