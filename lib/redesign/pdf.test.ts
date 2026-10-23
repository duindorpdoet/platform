import { beforeAll, describe, expect, it } from 'vitest';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createBookKeepsakePdf, setBookKeepsakeFonts } from './book-keepsake-pdf';
import { createGatePosterPdf, setPosterFonts } from './pdf-writer';
import type { BookSnapshot } from '@/lib/poortenboek/model';

beforeAll(() => {
  const regular = readFileSync('public/print/fonts/DejaVuSans.ttf'), bold = readFileSync('public/print/fonts/DejaVuSans-Bold.ttf');
  setBookKeepsakeFonts(regular, bold); setPosterFonts(regular, bold);
  if(process.env.REDESIGN_PDF_ARTIFACTS)mkdirSync(process.env.REDESIGN_PDF_ARTIFACTS,{recursive:true});
});
function snapshot(count: number): BookSnapshot {
  return {
    firstName: 'Avonturier', eventDate: '2026-10-31', election: { winner: 'Eigen team' },
    identity: { avatarId: 'moon-knight', lanternShape: 'crystal', lanternColor: 'violet' },
    journey: { complete: false, chapters: [{ chapter: 1, unlockedAt: '2026-10-23' }], seals: Array.from({ length: count }, (_, i) => ({ earnedAt: '2026-10-31T18:00:00Z', finale: false, presentation: { publicName: `Bereikte poort ${i + 1}`, world: 'Eigen wereld', shortDescription: 'Samen aangekomen' } })) },
    privateAddress: 'PRIVATE_ADDRESS_MUST_NOT_BE_PRINTED', credential: 'PRIVATE_CREDENTIAL_MUST_NOT_BE_PRINTED',
  } as unknown as BookSnapshot;
}
describe('real downloadable PDFs', () => {
  it.each([0, 2, 5, 40])('prints only the own %i seals and paginates long lists', (count) => {
    const bytes = createBookKeepsakePdf(snapshot(count)), data = Buffer.from(bytes).toString('latin1');
    expect(data.startsWith('%PDF-1.')).toBe(true); expect(data).toContain('/MediaBox [0 0 595.28 841.89]');
    expect(data).not.toContain('PRIVATE_ADDRESS'); expect(data).not.toContain('PRIVATE_CREDENTIAL');
    expect(data).not.toContain('(Finalezegel)');
    const pages = (data.match(/\/Type \/Page\b/g) ?? []).length; expect(pages).toBeGreaterThanOrEqual(count > 5 ? 3 : 1);
    if (process.env.REDESIGN_PDF_ARTIFACTS) { mkdirSync(process.env.REDESIGN_PDF_ARTIFACTS, { recursive: true }); writeFileSync(`${process.env.REDESIGN_PDF_ARTIFACTS}/book-${count}.pdf`, bytes); }
  });
  it.each(['mono', 'colour'] as const)('uses vector QR modules with an A4 %s poster', (mode) => {
    const bytes = createGatePosterPdf({ gateName: 'Oefenpoort', gateCode: 'P-01', shortCode: 'ISOLATED', arrivalUrl: 'https://example.invalid/omgeving/meeloper/route?code=isolated-fixture', eventDate: '2026-10-31', revision: 1 }, mode);
    const data = Buffer.from(bytes).toString('latin1'); expect(data).toContain('/MediaBox [0 0 595.28 841.89]');
    expect(data).toContain('(ISOLATED)'); expect(data).not.toContain('/Subtype /Image'); expect(data).not.toContain('DEMO-ONLY');
    if (process.env.REDESIGN_PDF_ARTIFACTS) writeFileSync(`${process.env.REDESIGN_PDF_ARTIFACTS}/poster-${mode}.pdf`, bytes);
  });
});
