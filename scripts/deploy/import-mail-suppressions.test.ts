import {describe,it,expect} from 'vitest';
import {canRetainLegacyProvider} from './import-mail-suppressions.mjs';
import {SuppressionSyncError} from './sendgrid-suppressions.mjs';
describe('independent app release with legacy provider retained',()=>{
 it('keeps SendGrid active when read access is missing without certifying an empty import',()=>expect(canRetainLegacyProvider(new SuppressionSyncError('SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED'),'sendgrid')).toBe(true));
 it('does not permit a Resend release to ignore an incomplete import',()=>expect(canRetainLegacyProvider(new SuppressionSyncError('SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED'),'resend')).toBe(false));
 it.each(['SUPPRESSION_IMPORT_STORAGE_FAILED','SENDGRID_SUPPRESSIONS_INVALID_RESPONSE','SENDGRID_SUPPRESSIONS_PAGINATION_REPEATED'])('does not conceal corrupt data or storage errors %s',code=>expect(canRetainLegacyProvider(new SuppressionSyncError(code),'sendgrid')).toBe(false));
});
