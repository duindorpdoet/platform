import {describe,it,expect} from 'vitest';
import {assertEquivalentHotfix} from './repair-portal-hotfix-history.mjs';
const proof={save_hash:'b173e2e2a2fe8341cb6e146e62be8b99',cleanup_hash:'ce66c8115d726e623cd6c638e5eef587',trigger_valid:true,contaminated_drafts:0,versions:['20261027033940']};
describe('metadata-only portal history repair',()=>{
 it('permits the legacy staging version only with identical installed definitions',()=>expect(()=>assertEquivalentHotfix({...proof,versions:['20261027032725']},proof)).not.toThrow());
 it.each([{save_hash:'changed'},{cleanup_hash:'changed'},{trigger_valid:false},{contaminated_drafts:1},{versions:[]}])('refuses incomplete or changed staging proof %j',change=>expect(()=>assertEquivalentHotfix({...proof,...change},proof)).toThrow());
 it('requires the canonical production history',()=>expect(()=>assertEquivalentHotfix(proof,{...proof,versions:['20261027032725']})).toThrow());
});
