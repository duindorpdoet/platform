"use client";
/* eslint-disable @next/next/no-html-link-for-pages, @next/next/no-location-assign-relative-destination -- A new credential requires a full document request, without retained Next router state. */
import { useEffect, useRef, useState } from "react";
import { ArrowRight, KeyRound, LockKeyhole, Sparkles } from "lucide-react";
import { MotionToggle } from "@/components/poorten-cinematic";
import { LOGIN_ERROR, normalizeCode } from "@/lib/poortenboek/model";

export function BookLogin({ demo = false }: { demo?: boolean }) {
  const [digits, setDigits] = useState<string[]>(Array(6).fill(""));
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const refs = useRef<Array<HTMLInputElement | null>>([]);
  const pending = useRef(false);
  useEffect(() => {
    const clear = () => setDigits(Array(6).fill(""));
    window.addEventListener("pageshow", clear);
    return () => window.removeEventListener("pageshow", clear);
  }, []);
  function fill(value: string, start: number) {
    const chars = normalizeCode(value)
      .replace(/[^A-Z0-9]/g, "")
      .slice(0, 6 - start)
      .split("");
    setDigits((current) =>
      current.map((digit, index) =>
        index >= start && index < start + chars.length
          ? chars[index - start]
          : digit,
      ),
    );
    refs.current[Math.min(5, start + chars.length)]?.focus();
  }
  async function login() {
    if (pending.current || digits.some((digit) => !digit)) return;
    pending.current = true;
    setBusy(true);
    setError("");
    try {
      const result = await fetch("/api/poortenboek/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: digits.join("") }),
        cache: "no-store",
      });
      if (!result.ok) {
        setError(LOGIN_ERROR);
        return;
      }
      setDigits(Array(6).fill(""));
      window.location.assign("/poortenboek");
    } catch {
      setError(LOGIN_ERROR);
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }
  return (
    <main className="pb-login" id="poortenboek-content">
      <picture className="pb-login-art">
        <source
          media="(min-width: 760px)"
          srcSet="/images/poortenboek/login-gate-wide.webp"
        />
        <img src="/images/poortenboek/login-gate.webp" alt="" />
      </picture>
      <a className="pb-login-brand" href="/">
        <img
          src="/images/logo.webp"
          alt="De Duindorpse Poorten van Halloween"
          width="210"
          height="90"
        />
      </a>
      {demo && (
        <span className="pb-demo-badge">
          <Sparkles size={14} />
          Demomodus
        </span>
      )}
      <div className="pb-login-panel">
        <span className="pb-medallion">
          <KeyRound />
        </span>
        <p className="pb-eyebrow">Jouw avontuur begint hier</p>
        <h1>
          Open jouw
          <br />
          <em>Poortenboek</em>
        </h1>
        <p>
          Een geheime code. Een eigen verhaal.
          <br />
          De poorten wachten op jou.
        </p>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void login();
          }}
          autoComplete="off"
        >
          <fieldset disabled={busy}>
            <legend>Jouw persoonlijke code van zes tekens</legend>
            <div
              className="pb-code-inputs"
              onPaste={(event) => {
                event.preventDefault();
                fill(event.clipboardData.getData("text"), 0);
              }}
            >
              {digits.map((digit, index) => (
                <input
                  key={index}
                  ref={(node) => {
                    refs.current[index] = node;
                  }}
                  aria-label={`Codeteken ${index + 1}`}
                  value={digit}
                  inputMode="text"
                  autoCapitalize="characters"
                  autoCorrect="off"
                  spellCheck={false}
                  autoComplete="off"
                  maxLength={6}
                  onFocus={(event) => event.target.select()}
                  onChange={(event) => {
                    if (!event.target.value)
                      setDigits((current) =>
                        current.map((value, i) => (i === index ? "" : value)),
                      );
                    else fill(event.target.value, index);
                  }}
                  onKeyDown={(event) => {
                    if (
                      event.key === "Backspace" &&
                      !digits[index] &&
                      index > 0
                    ) {
                      event.preventDefault();
                      setDigits((current) =>
                        current.map((value, i) =>
                          i === index - 1 ? "" : value,
                        ),
                      );
                      refs.current[index - 1]?.focus();
                    }
                    if (event.key === "ArrowLeft")
                      refs.current[Math.max(0, index - 1)]?.focus();
                    if (event.key === "ArrowRight")
                      refs.current[Math.min(5, index + 1)]?.focus();
                  }}
                />
              ))}
            </div>
          </fieldset>
          {error && (
            <p role="alert" className="pb-error">
              {error}
            </p>
          )}
          <button
            className="pb-button"
            type="submit"
            disabled={busy || digits.some((digit) => !digit)}
          >
            {busy ? "De poort wordt geopend…" : "Open mijn Poortenboek"}
            <ArrowRight size={18} />
          </button>
        </form>
        <p className="pb-help">
          <LockKeyhole size={15} />
          Je vindt jouw code bij de ouder die jou heeft ingeschreven.
        </p>
        <a className="pb-lost-code" href="#code-kwijt">
          Code kwijt? Vraag je ouder om jouw code te bekijken of te vernieuwen.
        </a>
        <p id="code-kwijt" className="pb-small">
          Je ouder kan dit doen in Mijn inschrijving, bij jouw Poortenboek.
        </p>
        {demo && (
          <p className="pb-demo-hint">
            Ontdek de fictieve reis van Mila met democode{" "}
            <strong>DEMO26</strong>.
          </p>
        )}
        <MotionToggle inline />
      </div>
      <p className="pb-login-foot">
        31 oktober 2026 <span>✦</span> Duindorp, Den Haag
      </p>
    </main>
  );
}
