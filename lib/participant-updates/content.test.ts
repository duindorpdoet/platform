import { describe, expect, it } from "vitest";
import { PARTICIPANT_UPDATE_BODY_LIMIT, renderParticipantUpdate } from "./content";

describe("organization Update rendering boundary", () => {
  it("preserves Enter and blank lines, including Windows and old Mac line endings", () => {
    const rendered = renderParticipantUpdate("Beste buren,\r\n\r\nEerste regel\rTweede regel\nTot straks!");
    expect(rendered.html).toBe("Beste buren,<br /><br />Eerste regel<br />Tweede regel<br />Tot straks!");
    expect(rendered.text).toBe("Beste buren,\n\nEerste regel\nTweede regel\nTot straks!");
  });

  it("keeps readable formatting, HTTPS images and a real plaintext alternative", () => {
    const rendered = renderParticipantUpdate('<p>Hallo <strong>buren</strong> &amp; vrienden.</p>\n<ul><li>Kom op tijd</li><li>Neem een lamp mee</li></ul><img src="https://images.example.invalid/flyer.jpg?a=1&amp;b=2" alt="Poster &amp; programma" width="640"><p><a href="https://halloween.duindorpdoet.nl/nieuws">Lees verder</a></p>');
    expect(rendered.html).toContain("<strong>buren</strong>");
    expect(rendered.html).toContain('src="https://images.example.invalid/flyer.jpg?a=1&amp;b=2"');
    expect(rendered.html).toContain('alt="Poster &amp; programma"');
    expect(rendered.html).toContain("max-width:100%;height:auto;display:block");
    expect(rendered.text).toContain("Hallo buren & vrienden.\n\n• Kom op tijd\n• Neem een lamp mee");
    expect(rendered.text).toContain("[Afbeelding: Poster & programma]");
    expect(rendered.text).toContain("Lees verder (https://halloween.duindorpdoet.nl/nieuws)");
    expect(rendered.text).not.toMatch(/<[^>]+>|&amp;/);
  });

  it.each([
    '<script>window.pwned=1</script><p>Veilig</p>',
    '<svg><script>window.pwned=1</script></svg><p>Veilig</p>',
    '<math><mtext><img src=x onerror="window.pwned=1"></mtext></math><p>Veilig</p>',
    '<iframe srcdoc="<script>window.pwned=1</script>"></iframe><p>Veilig</p>',
    '<style>body{display:none}</style><p onclick="window.pwned=1" id="login" class="admin">Veilig</p>',
    '<form action="https://bad.invalid"><input name="password"><p>Veilig</p></form>',
    '<img src="https://images.example.invalid/a.jpg" onerror="window.pwned=1"><p>Veilig</p>',
  ])("removes active content and application hooks: %s", (source) => {
    const rendered = renderParticipantUpdate(source);
    expect(rendered.html).toContain("Veilig");
    expect(rendered.html).not.toMatch(/script|svg|math|iframe|srcdoc|onclick|onerror|window\.pwned|<form|<input|id=|class=/i);
    expect(rendered.text).not.toContain("window.pwned");
  });

  it.each(["javascript:alert(1)", "data:image/svg+xml,x", "http://images.example.invalid/a.jpg", "//images.example.invalid/a.jpg", "/a.jpg", "https://user:pass@images.example.invalid/a.jpg"])("rejects unsafe or ambiguous image URL %s", (src) => {
    expect(renderParticipantUpdate(`<img src="${src}" alt="Poster">`).html).not.toContain("<img");
  });

  it("blocks encoded schemes and styles capable of hiding or replacing the app", () => {
    const { html } = renderParticipantUpdate('<a href="jav&#x61;script:alert(1)">Klik</a><a href="java&#10;script:alert(1)">Klik</a><p style="position:fixed;z-index:999999;background:url(https://bad.invalid/a);color:#ffaa00;text-align:center">Bericht</p>');
    expect(html).not.toContain("href=");
    expect(html).not.toMatch(/javascript|position|z-index|url\(|bad\.invalid/);
    expect(html).toContain("color:#ffaa00;text-align:center");
  });

  it.each(["noscript", "style", "textarea", "script", "xmp"])("does not activate CDATA-hidden content of %s (GHSA-2rjc-9xvg-45j7)", (tag) => {
    const source = `<p>Veilig</p><![CDATA[ x > <${tag}>]]><a href="https://hidden.example.invalid">Verborgen</a><img src="https://hidden.example.invalid/beacon.gif"></${tag}>`;
    const rendered = renderParticipantUpdate(source);
    expect(rendered.html.trim()).toBe("<p>Veilig</p>");
    expect(rendered.text).toBe("Veilig");
  });

  it("keeps escaped example code inert and repairs malformed allowed markup", () => {
    const rendered = renderParticipantUpdate('&lt;img src=x onerror=alert(1)&gt;\n<p><strong>Een<p>Twee');
    expect(rendered.html).toContain("&lt;img src=x onerror=alert(1)&gt;");
    expect(rendered.html).not.toContain("<img");
    expect(rendered.text).toContain("Een\nTwee");
  });

  it("handles the full server limit without truncating source and refuses over-limit input", () => {
    expect(renderParticipantUpdate("a".repeat(PARTICIPANT_UPDATE_BODY_LIMIT)).text).toHaveLength(PARTICIPANT_UPDATE_BODY_LIMIT);
    expect(() => renderParticipantUpdate("a".repeat(PARTICIPANT_UPDATE_BODY_LIMIT + 1))).toThrow(RangeError);
  });

  it("accepts the same Unicode character count as PostgreSQL char_length", () => {
    expect(renderParticipantUpdate("🎃".repeat(PARTICIPANT_UPDATE_BODY_LIMIT)).text).toBe("🎃".repeat(PARTICIPANT_UPDATE_BODY_LIMIT));
    expect(() => renderParticipantUpdate("🎃".repeat(PARTICIPANT_UPDATE_BODY_LIMIT + 1))).toThrow(RangeError);
  });
});
