import Link from "next/link";
import { WorkspaceHeader } from "./shared";
export function FestivalInfo({ title, children }: { title: string; children: React.ReactNode }) {
  return <div className="theme theme-poster"><WorkspaceHeader title="DUINDORP FRIGHTNIGHT 2027" /><main id="main-content" className="fn-workspace"><section className="fn-panel"><span className="ui-kicker">Staging · testversie 2027-test-v1</span><h1>{title}</h1>{children}<p><Link className="ui-button" href="/">Terug naar het festival</Link></p></section></main></div>;
}
