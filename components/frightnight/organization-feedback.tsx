import type { FrightnightSnapshot } from "@/lib/frightnight/model";

const feedbackTime = (value: string) => new Date(value).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam", dateStyle: "medium", timeStyle: "short" });

export function OrganizationFeedback({ snapshot }: { snapshot: FrightnightSnapshot }) {
  const feedback = snapshot.feedback;
  if (!snapshot.actor.capabilities.some(capability => capability === "event_admin" || capability === "content_manage")) return null;
  return <>
    <section className="fn-panel" aria-label="Algemene bedankjes aan de organisatie">
      <h2>BEDANKJES AAN DE ORGANISATIE.</h2>
      <p>Deelnemers bewaren hier hun algemene bedankje. Bedankjes aan een bezocht huis blijven bij die bewoner.</p>
      {!feedback ? <p>De server heeft voor jouw account nog geen actuele feedbacklijst bevestigd.</p> : feedback.organizationThanks.length ? feedback.organizationThanks.map(item => <article className="fn-notification" key={item.id}><div><h3>{item.label}</h3><p>{item.message}</p><time dateTime={item.createdAt}>{feedbackTime(item.createdAt)}</time></div></article>) : <p>Er zijn nog geen algemene bedankjes bewaard.</p>}
      <p className="fn-caption">Deze actuele serverlijst toont de laatste maximaal 100 algemene bedankjes van uitsluitend deze editie.</p>
    </section>
    <section className="fn-panel" aria-label="Evaluaties van afgeronde tochten">
      <h2>HOE WAS HUN NACHT?</h2>
      {!feedback ? <p>De server heeft voor jouw account nog geen actuele evaluatielijst bevestigd.</p> : feedback.evaluations.length ? feedback.evaluations.map(item => <article className="fn-notification" key={item.registrationId}><div><h3>{item.label} · {item.rating} van 5</h3>{item.message && <p>{item.message}</p>}<time dateTime={item.createdAt}>{feedbackTime(item.createdAt)}</time></div></article>) : <p>Er zijn nog geen evaluaties van afgeronde tochten bewaard.</p>}
      <p className="fn-caption">Deze lijst toont de laatste maximaal 100 evaluaties van deze editie. Een evaluatie vereist de bevestigde Duinpadfinale.</p>
    </section>
  </>;
}
