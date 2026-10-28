import { expect, it } from 'vitest';
import { recoveryQuery } from './recover-group-mail.mjs';
const id='94000000-0000-0000-0000-000000000001';
it('bounds incident recovery to explicit unique UUIDs and reviewed revision',()=>{
  for(const ids of [[],[id,id],Array.from({length:11},(_,i)=>`94000000-0000-0000-0000-${String(i).padStart(12,'0')}`),["';delete from x;"]])expect(()=>recoveryQuery(ids,'a'.repeat(40),id)).toThrow('INVALID_RECOVERY_SCOPE');
  expect(()=>recoveryQuery([id],'main',id)).toThrow('INVALID_RECOVERY_SCOPE');
  expect(()=>recoveryQuery([id],'a'.repeat(40),'bad')).toThrow('INVALID_RECOVERY_SCOPE');
});
