"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { Check, Copy, Download, ImageIcon, LoaderCircle, RotateCcw, Share2, Sparkles } from "lucide-react";
import { shareFormats, type ShareCard, type ShareContext, type ShareFormat, type ShareStyle } from "@/lib/social-share/catalog";

type Generated = {
  generationId: string;
  publicShareId: string;
  imageUrl: string;
  publicPageUrl: string;
  caption: string;
  cached: boolean;
};

function getSessionId() {
  const key = "deelstudio-session";
  const existing = sessionStorage.getItem(key);
  if (existing) return existing;
  const value = crypto.randomUUID();
  sessionStorage.setItem(key, value);
  return value;
}
function track(sessionId: string, eventType: string, card?: ShareCard, generated?: Generated, platform?: string) {
  void fetch("/api/deelstudio/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sessionId, eventType, templateKey: card?.key, publicShareId: generated?.publicShareId, platform }),
    keepalive: true,
  });
}

export function ShareStudio() {
  const [context, setContext] = useState<ShareContext | null>(null);
  const [selectedKey, setSelectedKey] = useState<string>("");
  const [format, setFormat] = useState<ShareFormat>("story");
  const [style, setStyle] = useState<ShareStyle>("event");
  const [generated, setGenerated] = useState<Generated | null>(null);
  const [caption, setCaption] = useState("");
  const [status, setStatus] = useState<"loading" | "ready" | "rendering" | "error">("loading");
  const [message, setMessage] = useState("");
  const [sessionId, setSessionId] = useState("");
  const card = useMemo(() => context?.cards.find((item) => item.key === selectedKey) ?? context?.cards[0], [context, selectedKey]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const session = getSessionId();
      setSessionId(session);
      fetch("/api/deelstudio/context", { cache: "no-store" })
      .then(async (response) => {
        const body = await response.json();
        if (!response.ok) throw new Error(body.error?.message ?? "De kaarten konden niet worden geladen.");
        return body.data as ShareContext;
      })
      .then((data) => {
        setContext(data);
        setSelectedKey(data.cards[0]?.key ?? "");
        setFormat(data.cards[0]?.formats.find((item) => item !== "opengraph") ?? "story");
        setStatus("ready");
        track(session, "studio_opened");
      })
      .catch((error: Error) => { setMessage(error.message); setStatus("error"); });
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  function chooseCard(item: ShareCard) {
    setSelectedKey(item.key);
    setGenerated(null);
    setCaption("");
    setMessage("");
    if (!item.worldStyleAvailable) setStyle("event");
    if (!item.formats.includes(format)) setFormat(item.formats.find((candidate) => candidate !== "opengraph") ?? "story");
    track(sessionId, "template_selected", item);
  }

  async function generate() {
    if (!card || !sessionId) return;
    setStatus("rendering");
    setMessage("Licht, mist en typografie worden samengebracht…");
    try {
      const response = await fetch("/api/deelstudio/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ templateKey: card.key, format, style, sessionId }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error?.message ?? "De kaart kon niet worden gemaakt.");
      setGenerated(body.data);
      setCaption(body.data.caption);
      setStatus("ready");
      setMessage("Jouw deelkaart is klaar.");
      track(sessionId, "preview_generated", card, body.data);
    } catch (error) {
      setStatus("error");
      setMessage(error instanceof Error ? error.message : "De kaart kon niet worden gemaakt.");
    }
  }

  async function copy(value: string, eventType: "caption_copied" | "link_copied") {
    await navigator.clipboard.writeText(value);
    setMessage(eventType === "caption_copied" ? "Bericht gekopieerd." : "Link gekopieerd.");
    track(sessionId, eventType, card, generated ?? undefined);
  }

  async function imageFile() {
    if (!generated) throw new Error("Maak eerst een kaart.");
    const response = await fetch(generated.imageUrl);
    if (!response.ok) throw new Error("De afbeelding kon niet worden opgehaald.");
    return new File([await response.blob()], `duindorpse-poorten-${format}.png`, { type: "image/png" });
  }

  async function download() {
    if (!generated) return;
    try {
      const file = await imageFile();
      const href = URL.createObjectURL(file);
      const anchor = document.createElement("a");
      anchor.href = href;
      anchor.download = file.name;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(href), 1_000);
      setMessage("Afbeelding opgeslagen.");
      track(sessionId, "image_downloaded", card, generated);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Opslaan lukte niet. Probeer het opnieuw.");
    }
  }

  async function share() {
    if (!generated || !card) return;
    try {
      const file = await imageFile();
      if (navigator.canShare?.({ files: [file] })) {
        const opened = navigator.share({ files: [file], text: caption, title: card.name });
        setMessage("Het deelmenu is geopend.");
        track(sessionId, "native_share_opened", card, generated, "native");
        await opened;
        return;
      }
      await download();
      await navigator.clipboard.writeText(caption);
      setMessage("Afbeelding opgeslagen en bericht gekopieerd. Open nu je favoriete social-app.");
      track(sessionId, "platform_fallback_opened", card, generated);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
      setMessage(error instanceof Error ? error.message : "Delen lukte niet. Download de afbeelding om verder te gaan.");
    }
  }

  if (status === "loading") return <div className="share-loading"><LoaderCircle className="spin" /><p>Deelkaarten worden klaargezet…</p></div>;
  if (!context || !card) return <div className="share-empty"><h2>Geen deelkaarten beschikbaar</h2><p>{message || "Kom later nog eens terug."}</p></div>;

  return (
    <div className="share-studio">
      <section className="share-stage" aria-labelledby="share-choose-title">
        <div className="share-section-heading"><span>01</span><div><p className="kicker">Kies wat je wilt delen</p><h2 id="share-choose-title">Een kaart voor jouw moment</h2></div></div>
        <div className="share-card-rail" role="list">
          {context.cards.map((item) => (
            <button key={item.key} type="button" className={`share-card-choice ${item.key === card.key ? "active" : ""}`} onClick={() => chooseCard(item)} aria-pressed={item.key === card.key}>
              <img src={item.portraitAsset} alt="" />
              <span><strong>{item.name}</strong><small>{item.textConfig.eyebrow ?? "Deel de magie"}</small></span>
              {item.key === card.key && <Check aria-hidden="true" />}
            </button>
          ))}
        </div>
      </section>

      <section className="share-stage share-config" aria-labelledby="share-style-title">
        <div className="share-section-heading"><span>02</span><div><p className="kicker">Vorm & sfeer</p><h2 id="share-style-title">Kies jouw uitsnede</h2></div></div>
        <div className="share-options">
          <div><h3>Stijl</h3><div className="share-segmented"><button type="button" className={style === "event" ? "active" : ""} onClick={() => setStyle("event")}>Eventstijl</button>{card.worldStyleAvailable && <button type="button" className={style === "world" ? "active" : ""} onClick={() => setStyle("world")}>Wereldstijl</button>}</div></div>
          <div><h3>Formaat</h3><div className="share-format-grid">{card.formats.filter((item) => item !== "opengraph").map((item) => <button key={item} type="button" className={format === item ? "active" : ""} onClick={() => setFormat(item)}><span style={{ aspectRatio: `${shareFormats[item].width}/${shareFormats[item].height}` }} /><strong>{shareFormats[item].label}</strong><small>{shareFormats[item].width} × {shareFormats[item].height}</small></button>)}</div></div>
        </div>
        <button className="btn share-generate" type="button" onClick={generate} disabled={status === "rendering"}>{status === "rendering" ? <LoaderCircle className="spin" /> : <Sparkles />} {status === "rendering" ? "De magie wordt gemaakt…" : "Maak mijn deelkaart"}</button>
        {message && <p className="share-status" role="status">{message}</p>}
      </section>

      {generated && (
        <section className="share-stage share-result" aria-labelledby="share-preview-title">
          <div className="share-section-heading"><span>03</span><div><p className="kicker">Zo ziet jouw bericht eruit</p><h2 id="share-preview-title">Klaar om de magie te delen?</h2></div></div>
          <div className="share-preview-layout">
            <div className={`share-preview share-preview-${format}`}><img src={generated.imageUrl} alt={`Voorbeeld van ${card.name} in formaat ${shareFormats[format].label}`} /></div>
            <div className="share-copy-panel">
              <label htmlFor="share-caption">Jouw bericht</label>
              <textarea id="share-caption" value={caption} onChange={(event) => setCaption(event.target.value)} rows={12} maxLength={4000} />
              <button className="text-link" type="button" onClick={() => setCaption(generated.caption)}><RotateCcw size={16} /> Herstel standaardtekst</button>
              <p className="share-privacy"><ImageIcon size={18} /> Deze afbeelding wordt openbaar wanneer je hem deelt. Er worden geen adressen of kindgegevens toegevoegd.</p>
              <div className="share-actions">
                <button className="btn" type="button" onClick={share}><Share2 /> Deel nu</button>
                <button className="btn outline" type="button" onClick={download}><Download /> Afbeelding opslaan</button>
                <button className="btn outline" type="button" onClick={() => copy(caption, "caption_copied")}><Copy /> Bericht kopiëren</button>
                <button className="btn ghost" type="button" onClick={() => copy(generated.publicPageUrl, "link_copied")}><Copy /> Link kopiëren</button>
              </div>
              <div className="share-platforms" aria-label="Platformhulp">
                <a href={`https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(generated.publicPageUrl)}`} target="_blank" rel="noreferrer" onClick={() => track(sessionId, "platform_fallback_opened", card, generated, "facebook")}>Facebook</a>
                <a href="https://www.instagram.com/" target="_blank" rel="noreferrer" onClick={() => track(sessionId, "platform_fallback_opened", card, generated, "instagram")}>Open Instagram</a>
                <a href={`https://twitter.com/intent/tweet?text=${encodeURIComponent(caption)}&url=${encodeURIComponent(generated.publicPageUrl)}`} target="_blank" rel="noreferrer" onClick={() => track(sessionId, "platform_fallback_opened", card, generated, "x")}>Open X</a>
              </div>
              <small className="share-help">Geen bestandsdeling? Sla de afbeelding op, kopieer je bericht en voeg de kaart in Instagram, Snapchat, WhatsApp of X toe.</small>
            </div>
          </div>
        </section>
      )}
      {!context.authenticated && <p className="share-login-note">Ingelogde deelnemers en poorteigenaren zien hier ook hun persoonlijke, privacyveilige kaarten. <Link href="/inloggen?next=/deel-de-magie">Log in</Link>.</p>}
    </div>
  );
}
