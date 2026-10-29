import { describe, expect, it, vi } from 'vitest';
import { backupKey, management, openBackup, sealBackup } from './redesign-preflight.mjs';
describe('private release inventory encryption',()=>{
  const secret=Buffer.alloc(32,7).toString('base64'),key=backupKey(secret);
  it('round trips without writing plaintext and uses fresh nonces',()=>{
    const value=Buffer.from('private fixture inventory'),a=sealBackup(value,key,'staging:sha'),b=sealBackup(value,key,'staging:sha');
    expect(a.equals(b)).toBe(false);expect(a.includes(value)).toBe(false);expect(openBackup(a,key,'staging:sha')).toEqual(value);
  });
  it('rejects a different environment or key and corrupted content',()=>{
    const data=sealBackup(Buffer.from('fixture'),key,'staging:sha');
    expect(()=>openBackup(data,key,'production:sha')).toThrow();
    expect(()=>openBackup(data,backupKey(Buffer.alloc(32,8).toString('base64')),'staging:sha')).toThrow();
    data[data.length-1]^=1;expect(()=>openBackup(data,key,'staging:sha')).toThrow();
  });
  it('requires the existing canonical 256-bit server key',()=>{expect(()=>backupKey('missing')).toThrow('BACKUP_KEY_UNAVAILABLE');});
});

it.each([
  [{code:'42501',message:'Private synthetic SQL content'},'PREFLIGHT_API_400_42501'],
  [{message:'Failed to run sql query: ERROR: 25006: cannot execute UPDATE in a read-only transaction; private fixture'},'PREFLIGHT_API_400_25006'],
  [{code:'private-row-data',message:'Private fixture details'},'PREFLIGHT_API_400'],
])('reports only a safe SQLSTATE for management errors',async(body,expected)=>{
  const fetch=vi.spyOn(globalThis,'fetch').mockResolvedValue(Response.json(body,{status:400}));
  try {await expect(management('/database/query',{read_only:true,query:'select 1'})).rejects.toThrow(new RegExp('^'+expected+'$'));}
  finally {fetch.mockRestore();}
});
