import { describe, expect, it } from "vitest";
import { csvField } from "./csv";

describe("bevoegde regie-export: spreadsheetvelden", () => {
  it("neutraliseert formuleprefixen ook na spaties, tabs, regeleinden en BOM", () => {
    for (const prefix of ["", " ", "\t", "\r", "\n", "\uFEFF", "  \n"]) {
      for (const formula of ["=1+1", "+1+1", "-1+1", "@SUM(1)"]) {
        expect(csvField(prefix + formula)).toBe(`"'${prefix}${formula}"`);
      }
    }
    for (const value of ["\ttekst", "\rtekst", "\ntekst"]) expect(csvField(value)).toBe(`"'${value}"`);
  });
  it("behoudt normale tekst, puntkomma's, quotes en meerregelige velden als één quoted cel", () => {
    expect(csvField('Gezin "De Duinen"; samen\nnaar het plein')).toBe('"Gezin ""De Duinen""; samen\nnaar het plein"');
    expect(csvField(4)).toBe('"4"'); expect(csvField(null)).toBe('""');
  });
});
