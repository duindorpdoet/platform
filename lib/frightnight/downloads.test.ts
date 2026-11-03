import { describe, it, expect } from "vitest";
import { escapeHtml, printDocument } from "./downloads";
describe("veilige persoonlijke downloads", () => {
  it("escapet HTML in alle gebruikersvelden en noemt expliciet staging", () => {
    expect(escapeHtml('<script>"&')).toBe("&lt;script&gt;&quot;&amp;");
    const result = printDocument("<img src=x onerror=alert(1)>", "<p>Eigen gegevens</p>");
    expect(result).not.toContain("<title><img"); expect(result).toContain("STAGING / TEST");
  });
});
