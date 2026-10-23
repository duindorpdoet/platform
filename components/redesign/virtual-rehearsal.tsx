"use client";
import { useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Check, CheckCircle2, ChevronRight, ClipboardCheck, Download, FlaskConical, House, LoaderCircle, Play, RotateCcw, ShieldCheck, UsersRound, Wifi, WifiOff, XCircle } from 'lucide-react';
import { executeRehearsalScenario, rehearsalScenarios, type RehearsalResult, type RehearsalStep } from '@/lib/redesign/rehearsal-scenarios';
import '../../modern/virtual-rehearsal.css';

const REPORT_KEY = 'duindorp-virtual-rehearsal-v1';
function readReport(): Record<string, RehearsalResult> {
  try { const stored = JSON.parse(localStorage.getItem(REPORT_KEY) || 'null'); if (stored?.version !== 1 || !Array.isArray(stored.results)) return {}; return Object.fromEntries(stored.results.filter((item: RehearsalResult) => rehearsalScenarios.some(s => s.id === item.scenarioId) && typeof item.passed === 'boolean' && Array.isArray(item.steps) && item.steps.every(step => step.view && Array.isArray(step.view.children) && Array.isArray(step.view.history) && step.view.parent && step.view.gate)).map((item: RehearsalResult) => [item.scenarioId, item])); } catch { return {}; }
}
function saveReport(results: Record<string, RehearsalResult>) { try { localStorage.setItem(REPORT_KEY, JSON.stringify({ version: 1, results: Object.values(results) })); } catch { /* Results remain available in this screen. */ } }
function time(value: string) { return new Date(value).toLocaleTimeString('nl-NL', { timeZone: 'Europe/Amsterdam', hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
const statusLabel: Record<string, string> = { before: 'Voor vertrek', live: 'Onderweg', paused: 'Gepauzeerd', completed: 'Avond afgerond', stopped: 'Eigen avond afgerond', open: 'Open', closed: 'Gesloten', paused_gate: 'Pauze', pending: 'Nog te kiezen', visited: 'Doet mee', skipped: 'Kijkt rustig mee', present: 'Aanwezig', absent: 'Afwezig', departed: 'Naar huis', not_started: 'Voor vertrek' };

export function VirtualRehearsal() {
  const [results, setResults] = useState<Record<string, RehearsalResult>>(readReport);
  const [selected, setSelected] = useState(rehearsalScenarios[0].id);
  const [running, setRunning] = useState<string | null>(null);
  const [liveSteps, setLiveSteps] = useState<RehearsalStep[]>([]);
  const [stepIndex, setStepIndex] = useState(-1);
  const [perspective, setPerspective] = useState<'parent' | 'gate' | 'children'>('children');
  const [notice, setNotice] = useState('');
  const busy = useRef(false);
  const selectedScenario = rehearsalScenarios.find(item => item.id === selected)!;
  const result = results[selected];
  const steps = running === selected ? liveSteps : result?.steps ?? [];
  const visibleIndex = stepIndex < 0 ? steps.length - 1 : Math.min(stepIndex, steps.length - 1);
  const activeStep = steps[visibleIndex];
  const finished = Object.values(results), passed = finished.filter(item => item.passed).length;
  const failed = finished.filter(item => !item.passed).length;
  const assertions = finished.reduce((count, item) => count + item.steps.length, 0);
  const lastRun = finished.reduce((last, item) => item.endedAt > last ? item.endedAt : last, '');

  async function run(ids: string[]) {
    if (busy.current) return;
    busy.current = true; setNotice('');
    let updated = { ...results };
    try {
      for (const id of ids) {
        setSelected(id); setRunning(id); setLiveSteps([]); setStepIndex(-1);
        const output = await executeRehearsalScenario(id, step => setLiveSteps(current => [...current, step]));
        updated = { ...updated, [id]: output }; setResults(updated); saveReport(updated);
        await new Promise(resolve => window.setTimeout(resolve, 35));
      }
      const outcomes = ids.map(id => updated[id]);
      setNotice(outcomes.every(item => item?.passed) ? `${ids.length === 1 ? 'Dit scenario is' : `Alle ${ids.length} scenario’s zijn`} geslaagd. Bekijk hieronder de gemeten stappen.` : 'Een controle vraagt aandacht. Open het scenario voor de verwachting en de werkelijke uitkomst.');
    } catch (error) { setNotice(error instanceof Error ? error.message : 'De repetitie kon niet worden afgerond. Probeer opnieuw.'); }
    finally { setRunning(null); busy.current = false; }
  }
  function reset() { if (busy.current) return; setResults({}); saveReport({}); setLiveSteps([]); setStepIndex(-1); setNotice('Het repetitierapport is gewist. De echte tochten en kinderboeken zijn niet gewijzigd.'); }
  function downloadReport() {
    const report = { title: 'Virtuele generale repetitie — Duindorpse Poorten', generatedAt: new Date().toISOString(), environment: 'Geïsoleerde servertransactie met tijdelijke oefengegevens', scope: 'Routecommando’s, aankomstregistratie en zegeluitkomsten. Camera, echt mobiel internet, productiebelasting en fysieke posters vragen een praktijktest.', summary: { scenarios: rehearsalScenarios.length, checked: finished.length, passed, failed, assertions }, results: finished };
    const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' }));
    const link = document.createElement('a'); link.href = url; link.download = 'Duindorp-generale-repetitie.json'; document.body.appendChild(link); link.click(); link.remove(); window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
    setNotice('Het rapport met gemeten stappen staat in je downloads.');
  }

  return <section className="virtual-rehearsal" aria-labelledby="vr-title">
    <header className="vr-hero"><div className="vr-hero-copy"><span className="vr-eyebrow"><FlaskConical size={15}/> VIRTUELE GENERALE REPETITIE</span><h2 id="vr-title">Oefen de hele avond.</h2><p>Van vertrek tot laatste zegel. Test herkenbare situaties met een eigen virtuele groep en bekijk direct wat de groepsleider, poort en kinderboeken zien.</p><span className="vr-isolation"><ShieldCheck size={15}/>Eigen testgroep · echte prototypelogica · voorbeeldgegevens blijven intact</span></div><div className="vr-hero-stat"><span>{passed}<small> / {rehearsalScenarios.length}</small></span><strong>scenario’s geslaagd</strong><p>{finished.length ? `${assertions} stappen gecontroleerd` : 'Nog geen controles uitgevoerd'}</p></div></header>
    <div className="vr-toolbar"><div><button type="button" className="btn" disabled={Boolean(running)} onClick={() => void run(rehearsalScenarios.map(item => item.id))}>{running ? <LoaderCircle size={17} className="spin"/> : <Play size={17}/>} {running ? 'Repetitie loopt…' : 'Start volledige repetitie'}</button><button type="button" className="btn outline" disabled={Boolean(running) || !finished.length} onClick={downloadReport}><Download size={17}/>Rapport downloaden</button><button type="button" className="vr-reset" disabled={Boolean(running) || !finished.length} onClick={reset}><RotateCcw size={15}/>Rapport wissen</button></div><span>{lastRun ? `Laatste controle ${time(lastRun)}` : 'Elke controle begint met een nieuwe testgroep'}</span></div>
    {notice && <p className={`vr-notice ${failed ? 'has-attention' : ''}`} role="status"><ClipboardCheck size={17}/>{notice}</p>}
    <div className="vr-workspace"><nav className="vr-scenarios" aria-label="Repetitiescenario’s"><div className="vr-list-heading"><span>{rehearsalScenarios.length} scenario’s</span><small>{finished.length} uitgevoerd</small></div>{rehearsalScenarios.map((scenario, i) => { const checked = results[scenario.id], isRunning = running === scenario.id; return <button type="button" key={scenario.id} className={`vr-scenario ${selected === scenario.id ? 'is-selected' : ''}`} onClick={() => { setSelected(scenario.id); setStepIndex(-1); }} aria-pressed={selected === scenario.id}><span className={`vr-case-number ${isRunning ? 'is-running' : checked ? checked.passed ? 'is-passed' : 'is-failed' : ''}`}>{isRunning ? <LoaderCircle size={17} className="spin"/> : checked ? checked.passed ? <Check size={16}/> : <XCircle size={16}/> : String(i + 1).padStart(2, '0')}</span><span><small>{scenario.category}</small><strong>{scenario.title}</strong></span><ChevronRight size={16}/></button>; })}</nav>
      <div className="vr-detail"><header className="vr-case-heading"><div><span className="vr-eyebrow">{selectedScenario.category}</span><h3>{selectedScenario.title}</h3><p>{selectedScenario.description}</p></div><button type="button" className="btn outline" disabled={Boolean(running)} onClick={() => void run([selected])}><Play size={15}/>{result ? 'Opnieuw testen' : 'Test dit scenario'}</button></header>
        {!steps.length ? <div className="vr-empty"><FlaskConical size={35}/><h4>Deze situatie staat klaar.</h4><p>Start dit scenario of de volledige repetitie. Daarna zie je per stap de verwachting, uitkomst en het beeld voor deelnemers.</p><span>Er wordt pas een vinkje gezet als de uitkomst klopt.</span></div> : <>
          <div className="vr-result-banner"><span className={running === selected ? 'running' : result?.passed ? 'passed' : 'failed'}>{running === selected ? <LoaderCircle size={17} className="spin"/> : result?.passed ? <CheckCircle2 size={17}/> : <XCircle size={17}/>} {running === selected ? 'Wordt gecontroleerd' : result?.passed ? 'Scenario geslaagd' : 'Controle vraagt aandacht'}</span><small>{steps.filter(step => step.passed).length} van {steps.length} stappen kloppen{result?.endedAt ? ` · ${time(result.endedAt)}` : ''}</small></div>
          <ol className="vr-step-list">{steps.map((step, i) => <li key={`${step.command}-${i}`}><button type="button" className={visibleIndex === i ? 'is-active' : ''} onClick={() => setStepIndex(i)} aria-current={visibleIndex === i ? 'step' : undefined}><span className={step.passed ? 'vr-step-check' : 'vr-step-check failed'}>{step.passed ? <Check size={13}/> : <XCircle size={13}/>}</span><span><strong>{step.title}</strong><small>{step.actual}</small></span><time>{time(step.at)}</time></button></li>)}</ol>
          {activeStep && <div className="vr-inspector"><div className="vr-inspector-top"><div><span className="vr-eyebrow">BEKIJK DE UITKOMST</span><h4>Na stap {visibleIndex + 1}: {activeStep.title}</h4></div><div className="vr-step-arrows"><button type="button" aria-label="Vorige repetitiestap" disabled={visibleIndex <= 0} onClick={() => setStepIndex(visibleIndex - 1)}><ArrowLeft size={16}/></button><span>{visibleIndex + 1}/{steps.length}</span><button type="button" aria-label="Volgende repetitiestap" disabled={visibleIndex >= steps.length - 1} onClick={() => setStepIndex(visibleIndex + 1)}><ArrowRight size={16}/></button></div></div>
            <div className="vr-expectation"><span>Verwacht</span><p>{activeStep.expectation}</p></div><div className={`vr-actual ${activeStep.passed ? '' : 'failed'}`}><span>Gemeten</span><p>{activeStep.actual}</p></div>
            <div className="vr-perspective-tabs" role="group" aria-label="Bekijk als"><button type="button" aria-pressed={perspective === 'parent'} onClick={() => setPerspective('parent')}><UsersRound size={15}/>Groepsleider</button><button type="button" aria-pressed={perspective === 'gate'} onClick={() => setPerspective('gate')}><House size={15}/>Poortteam</button><button type="button" aria-pressed={perspective === 'children'} onClick={() => setPerspective('children')}><ShieldCheck size={15}/>Kinderboeken</button></div>
            <div className="vr-perspective"><div className={`vr-connection ${activeStep.view.connected ? '' : 'offline'}`}>{activeStep.view.connected ? <Wifi size={14}/> : <WifiOff size={14}/>} {activeStep.view.connected ? 'Virtuele verbinding beschikbaar' : 'Virtuele verbinding onderbroken'}</div>
              {perspective === 'parent' && <div className="vr-parent-view"><span className="vr-mini-label">GROEP G-01 · VIRTUEEL</span><h5>{activeStep.view.parent.stop}</h5><p>{statusLabel[activeStep.view.parent.status] ?? activeStep.view.parent.status}</p><div className="vr-mini-metrics"><span><strong>{activeStep.view.history.filter(item => item.arrived).length}</strong>Aankomsten</span><span><strong>{activeStep.view.parent.sequence || '—'}</strong>Actieve poort</span><span><strong>{activeStep.view.parent.version}</strong>Routeversie</span></div>{activeStep.view.parent.endedEarly && <p className="vr-warm-note">Jij bracht licht in Duindorp. Jouw verzamelde zegels blijven van jou.</p>}{activeStep.view.history.length > 0 && <div className="vr-history">{activeStep.view.history.map(item => <span key={item.sequence}><CheckCircle2 size={13}/>{item.sequence}. {item.name}<small>{item.arrived ? 'Aangekomen' : 'Systeemoverslag'}</small></span>)}</div>}</div>}
              {perspective === 'gate' && <div className="vr-gate-view"><span className="vr-mini-label">{activeStep.view.gate.code} · POORTBEELD</span><h5>{activeStep.view.gate.name}</h5><p>{statusLabel[activeStep.view.gate.status] ?? activeStep.view.gate.status}</p><div className="vr-gate-confirm"><House size={22}/><div><strong>{activeStep.view.gate.scanned ? 'Aankomstcode bevestigd' : 'Nog geen code bevestigd bij deze poort'}</strong><span>{activeStep.view.parent.status === 'live' ? 'De actuele bestemming van de virtuele groep.' : 'Er staat nu geen actieve aankomst klaar.'}</span></div></div><p className="vr-view-note">Na het afronden van een aankomst toont dit beeld de nieuwe actieve poort.</p></div>}
              {perspective === 'children' && <div className="vr-child-views">{activeStep.view.children.map((child, i) => <article key={child.id}><span className={`vr-child-avatar avatar-${i}`}>{child.name.slice(0, 1)}</span><h5>{child.name}</h5><small>{statusLabel[child.attendance] ?? child.attendance}</small><strong className="vr-seal-count">{child.seals}<span>{child.seals === 1 ? 'poortzegel' : 'poortzegels'}</span></strong><p>{child.finaleSeals ? 'Inclusief finalezegel' : child.attendance === 'departed' ? 'Jouw aankomsten blijven bewaard' : child.attendance === 'absent' ? 'Niet met deze groep vertrokken' : 'Elke bevestigde aankomst telt'}</p></article>)}</div>}
            </div><details className="vr-technical"><summary>Technische controle</summary><code>{activeStep.command}</code><p>Gemeten op {time(activeStep.at)} · {activeStep.durationMs} ms. Uitgevoerd met dezelfde geautoriseerde SQL-routecommando’s als de applicatie, in een eigen tijdelijke testgroep.</p></details>
          </div>}
        </>}
      </div>
    </div><footer className="vr-scope"><ShieldCheck size={18}/><p><strong>Wat deze repetitie controleert</strong>Routegedrag, blokkades, herhaalde opdrachten en aankomstzegels worden echt uitgevoerd en vergeleken. Test de camera, afgedrukte posters, mobiele dekking en productieomgeving ook een keer op locatie.</p></footer>
  </section>;
}
