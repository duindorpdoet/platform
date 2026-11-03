import { createHash } from 'node:crypto';
import { open, readdir } from 'node:fs/promises';
import { basename, join } from 'node:path';

export const timerScope=source=>/duindorphalloweenstg|staging-halloween\.duindorpdoet\.nl|nocteiuvohesvqbowchw|frightnight|app_private\.fn_/i.test(source)?'staging-or-frightnight':/duindorphalloweenprod|halloween\.duindorpdoet\.nl|dtubngvxfbupgvgfrjko/i.test(source)?'other-site':'unclassified-system';
export function summarizeSystemCronFile(directory,name,bytes) {
  if(name!==basename(name)||bytes.length>131072)throw new Error('SYSTEM_CRON_FILE_BOUND_EXCEEDED');
  return {directory,name,status:'read',sha256:createHash('sha256').update(bytes).digest('hex'),scope:timerScope(directory+'/'+name+'\n'+bytes.toString('utf8'))};
}
export async function inventorySystemCron() {
  const files=[],directories=[];
  async function read(directory,name) {
    let file;
    try {
      file=await open(join(directory,name),'r');const stat=await file.stat();
      if(!stat.isFile()){files.push({directory,name,status:'non-regular',scope:timerScope(directory+'/'+name)});return;}
      if(stat.size>131072)throw new Error('SYSTEM_CRON_FILE_BOUND_EXCEEDED');
      const bytes=Buffer.alloc(131073);let length=0;
      while(length<bytes.length) {const result=await file.read(bytes,length,bytes.length-length,length);if(!result.bytesRead)break;length+=result.bytesRead;}
      files.push(summarizeSystemCronFile(directory,name,bytes.subarray(0,length)));
    } catch(error) {
      if(error.message==='SYSTEM_CRON_FILE_BOUND_EXCEEDED')throw error;
      files.push({directory,name,status:error.code==='ENOENT'?'absent':'unavailable',scope:timerScope(directory+'/'+name)});
    } finally {await file?.close();}
  }
  await read('/etc','crontab');await read('/etc','anacrontab');
  for(const directory of ['/etc/cron.d','/etc/cron.hourly','/etc/cron.daily','/etc/cron.weekly','/etc/cron.monthly']) {
    let entries;
    try {entries=await readdir(directory,{withFileTypes:true});directories.push({directory,status:'read'});}
    catch(error){directories.push({directory,status:error.code==='ENOENT'?'absent':'unavailable'});continue;}
    if(entries.length>64||files.length+entries.length>256)throw new Error('SYSTEM_CRON_INVENTORY_BOUND_EXCEEDED');
    for(const entry of entries.sort((a,b)=>a.name.localeCompare(b.name)))await read(directory,entry.name);
  }
  return {files,directories,boundaries:['Private/root and other-user crontabs are not read; no sudo or permission bypass.','Only reachable system cron files are inventoried; unreadable files and directories remain explicit limits.']};
}
export function unreviewedSystemCron(files,reviewed) {
  return files.filter(file=>file.scope==='staging-or-frightnight'&&(file.status!=='read'||!reviewed.has(file.sha256)));
}
