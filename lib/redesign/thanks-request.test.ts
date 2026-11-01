import {describe,it,expect} from 'vitest';
import {closedThanksRequest} from './thanks-request';
const requestKey='e1000000-0000-4000-8000-000000000001';
describe('explicit post-event thanks request',()=>{
 it('preserves newlines and treats HTML-shaped text as text',()=>{const result=closedThanksRequest.parse({kind:'all',requestKey,message:'Een regel\n<script>tekst</script>'});expect(result.message).toBe('Een regel\n<script>tekst</script>');});
 it('allows a personal reaction without required free text',()=>expect(closedThanksRequest.parse({kind:'personal',requestKey,portalId:requestKey,choice:'welcome'}).message).toBe(''));
 it('limits text and accepts no client-selected account or household',()=>{expect(closedThanksRequest.safeParse({kind:'all',requestKey,message:'x'.repeat(501)}).success).toBe(false);expect(closedThanksRequest.safeParse({kind:'all',requestKey,accountId:requestKey}).success).toBe(false);});
});
