import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { userInfo } from 'node:os';
import { join } from 'node:path';
import { assertFrightnightRelease } from './frightnight-release.mjs';
import { inventorySystemCron,timerScope,unreviewedSystemCron } from './frightnight-system-cron.mjs';

assertFrightnightRelease(process.env);
if (userInfo().username !== 'duindorphalloweenstg' || process.env.RUNNER_NAME !== 'dg-sites-vps-01-duindorphalloweenstg-01'
    || !process.env.GITHUB_WORKSPACE?.startsWith('/srv/sites/duindorphalloweenstg/actions-runner/_work/')) throw new Error('DEDICATED_STAGING_TIMER_AUDIT_REQUIRED');
const directory=join(process.env.RUNNER_TEMP,'frightnight-operations');await mkdir(directory,{recursive:true,mode:0o700});
const digest=value=>createHash('sha256').update(value).digest('hex');
function read(command,args) {
  const result=spawnSync(command,args,{encoding:'utf8',timeout:5000,maxBuffer:2_000_000});
  return {ok:result.status===0,status:result.status,errorCode:result.error?.code,stdout:result.stdout??'',stderr:result.stderr??''};
}
const scope=timerScope;
const cron=read('crontab',['-l']);
const cronAbsent=cron.status===1&&/no crontab for/i.test(cron.stderr);
const cronLines=cron.ok?cron.stdout.split('\n').map(line=>line.trim()).filter(line=>line&&!line.startsWith('#')&&!/^[A-Z_][A-Z0-9_]*\s*=/.test(line)):[];
// Never print crontab contents, environment assignments or ExecStart arguments:
// these may contain historical credentials. Record hashes and names only.
const report={revision:process.env.GITHUB_SHA,recordedAt:new Date().toISOString(),user:'duindorphalloweenstg',readOnly:true,
 crontab:{status:cron.ok?'read':cronAbsent?'absent':'unavailable',entries:cronLines.map(line=>({sha256:digest(line),scope:scope(line)}))},systemTimers:[],userTimers:[]};
for(const user of [false,true]) {
  const prefix=user?['--user']:[];
  const list=read('systemctl',[...prefix,'list-timers','--all','--no-pager','--no-legend','--plain']);
  const unavailableUser=user&&!list.ok&&/Failed to connect to (?:user scope )?bus|No medium found|No such file or directory/i.test(list.stderr);
  // A missing runner DBUS/XDG variable alone does not prove no user timers run.
  const manager=unavailableUser?read('systemctl',['show',`user@${userInfo().uid}.service`,'--property=ActiveState','--value']):null;
  const noActiveUserManager=manager?.ok&&['inactive','failed'].includes(manager.stdout.trim());
  report[user?'userTimerStatus':'systemTimerStatus']=list.ok?'read':noActiveUserManager?'no-active-user-manager':'unavailable';
  if(!list.ok)continue;
  for(const line of list.stdout.split('\n')) {
    const names=line.trim().match(/(\S+\.timer)\s+(\S+\.(?:service|target))\s*$/);if(!names)continue;
    const state=read('systemctl',[...prefix,'show',names[1],'--property=ActiveState','--value']);
    const command=read('systemctl',[...prefix,'show',names[2],'--property=ExecStart','--value']);
    report[user?'userTimers':'systemTimers'].push({timer:names[1],activates:names[2],state:state.ok?state.stdout.trim():'unavailable',commandReadable:command.ok,commandSha256:command.ok?digest(command.stdout):null,scope:command.ok?scope(command.stdout):'unavailable'});
  }
}
// A command owned by the dedicated staging user also needs review when its
// generic executable name does not reveal the site it affects.
const scoped=[...report.crontab.entries,...report.userTimers,...report.systemTimers.filter(entry=>entry.scope==='staging-or-frightnight')];
const reviewed=new Set((process.env.FRIGHTNIGHT_REVIEWED_TIMER_SHA256??'').split(',').filter(Boolean));
report.systemCron=await inventorySystemCron();
report.unreviewedSystemCron=unreviewedSystemCron(report.systemCron.files,reviewed).length;
report.unreviewedScopedTimers=scoped.filter(entry=>!reviewed.has(entry.sha256??entry.commandSha256)).length+report.unreviewedSystemCron;
report.unreadableTimerCommands=[...report.systemTimers,...report.userTimers].filter(entry=>!entry.commandReadable).length;
report.complete=['read','absent'].includes(report.crontab.status)&&report.systemTimerStatus==='read'&&['read','no-active-user-manager'].includes(report.userTimerStatus)&&report.unreviewedScopedTimers===0&&report.unreadableTimerCommands===0;
await writeFile(join(directory,'vps-timers.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({vpsTimerInventory:report.complete?'passed':'review-required',crontab:report.crontab.status,systemTimers:report.systemTimers.length,userTimers:report.userTimers.length,systemCronFiles:report.systemCron.files.length,unreviewedScopedTimers:report.unreviewedScopedTimers,unreadableTimerCommands:report.unreadableTimerCommands,readOnly:true}));
if(!report.complete)throw new Error('VPS_TIMER_INVENTORY_REQUIRES_REVIEW_BEFORE_SEED');
