// Runs only in the existing dedicated staging environment. Never reads env files,
// removes releases/backups, or follows workspace cache symlinks outside the checkout.
import {lstat,realpath,rm,statfs} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join,relative,sep} from 'node:path';
const root='/srv/sites/duindorphalloweenstg';
const runner=join(root,'actions-runner');
const workspace=process.env.GITHUB_WORKSPACE;
const action=process.env.MAINTENANCE_ACTION;
if(process.env.GITHUB_REF!=='refs/heads/staging'||process.env.RUNNER_NAME!=='dg-sites-vps-01-duindorphalloweenstg-01'
 ||execFileSync('id',['-un'],{encoding:'utf8'}).trim()!=='duindorphalloweenstg'
 ||!workspace?.startsWith(join(runner,'_work')+sep)||!['inspect','clear-build-cache'].includes(action))throw new Error('STAGING_RUNNER_BOUNDARY_REQUIRED');
const resolvedWorkspace=await realpath(workspace);
if(!resolvedWorkspace.startsWith(join(runner,'_work')+sep))throw new Error('WORKSPACE_SYMLINK_OUTSIDE_RUNNER');
const caches=[join(workspace,'.next/cache'),join(workspace,'node_modules/.cache')];
async function present(path){try{return await lstat(path);}catch(error){if(error.code==='ENOENT')return null;throw error;}}
function measure(command,args){console.log(execFileSync(command,args,{encoding:'utf8',timeout:180000,maxBuffer:2*1024*1024}).trim());}
measure('df',['-h',root]);
for(const directory of [join(runner,'_work'),workspace,join(root,'releases')])if(await present(directory))measure('du',['-xhd1',directory]);
for(const path of caches)if(await present(path))measure('du',['-xsh',path]);
if(action==='clear-build-cache'){
 for(const path of caches){
  const entry=await present(path);if(!entry)continue;
  const resolved=await realpath(path),inside=relative(resolvedWorkspace,resolved);
  if(entry.isSymbolicLink()||inside.startsWith('..'+sep)||inside==='..'||!inside||inside.startsWith(sep))throw new Error('CACHE_OUTSIDE_WORKSPACE');
  await rm(path,{recursive:true,force:false});console.log(`Rebuildable cache cleared: ${relative(workspace,path)}`);
 }
}
const disk=await statfs(root);
console.log(JSON.stringify({action,availableBytes:disk.bavail*disk.bsize,availableGiB:Number((disk.bavail*disk.bsize/1024**3).toFixed(2)),deployment:false}));
measure('df',['-h',root]);
