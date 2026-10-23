import { describe, expect, it } from 'vitest';
import { backupKey, openBackup, sealBackup } from './redesign-preflight.mjs';
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
