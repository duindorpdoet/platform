import { describe, expect, it, vi } from 'vitest';
import { verifyEditionBoundary } from './frightnight-edition-boundary.mjs';
const parentSlug='frightnight-2027-test-acceptance-guard',parentEventId='00000000-0000-4000-8000-000000000001';
function fixture(foreignStatus=403) {
  const select=vi.fn(async(slug:string)=>({status:slug.endsWith('-foreign')?foreignStatus:200,selected:slug}));
  const readContext=vi.fn(async()=>({eventId:parentEventId,slug:parentSlug,signedCookie:'signed-parent-fixture'}));
  return {canonicalSlug:'frightnight-2027-test',parentSlug,parentEventId,foreignSlug:parentSlug+'-foreign',foreignEventId:'00000000-0000-4000-8000-000000000002',select,readContext};
}
describe('canonical entry and private sibling selection proof',()=>{
  it('proves allowed canonical entry, restores parent and denies a genuinely foreign edition',async()=>{
    const f=fixture();expect(await verifyEditionBoundary(f)).toEqual({canonicalEntry:true,privateSiblingDenied:true,signedParentContextUnchanged:true});
    expect(f.select.mock.calls.map(([slug])=>slug)).toEqual(['frightnight-2027-test',parentSlug,parentSlug+'-foreign']);expect(f.readContext).toHaveBeenCalledTimes(2);
  });
  it.each([200,401,404,500])('rejects a foreign response %s instead of accepting a weaker denial',async status=>{
    await expect(verifyEditionBoundary(fixture(status))).rejects.toThrow('FOREIGN_PRIVATE_EDITION_SELECTION_ALLOWED');
  });
  it('rejects canonical restriction and a denied response that changes the signed parent context',async()=>{
    const denied=fixture();denied.select.mockResolvedValueOnce({status:403,selected:''});await expect(verifyEditionBoundary(denied)).rejects.toThrow('CONFIRMED_CANONICAL_ENTRY_DENIED');expect(denied.select).toHaveBeenCalledTimes(1);
    const changed=fixture();changed.readContext.mockResolvedValueOnce({eventId:parentEventId,slug:parentSlug,signedCookie:'original'});await expect(verifyEditionBoundary(changed)).rejects.toThrow('DENIED_SELECTION_CHANGED_SIGNED_CONTEXT');
  });
  it('cannot substitute canonical or the same event as the supposedly foreign fixture',async()=>{
    for(const scope of [{foreignSlug:'frightnight-2027-test'},{foreignEventId:parentEventId}]){const f=fixture();await expect(verifyEditionBoundary({...f,...scope})).rejects.toThrow('FOREIGN_PRIVATE_EDITION_PROOF_REQUIRED');expect(f.select).not.toHaveBeenCalled();}
  });
});
