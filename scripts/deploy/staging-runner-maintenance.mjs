// Runs only in the existing dedicated staging environment. Never reads env files,
// removes releases/backups, or follows workspace cache symlinks outside the checkout.
import {lstat,realpath,rm,statfs} from 'node:fs/promises';
import {execFileSync,spawnSync} from 'node:child_process';
import {join,relative,sep} from 'node:path';
const root='/srv/sites/duindorphalloweenstg';
const runner=join(root,'actions-runner');
const workspace=process.env.GITHUB_WORKSPACE;
const action=process.env.MAINTENANCE_ACTION;
if(process.env.GITHUB_REF!=='refs/heads/staging'||process.env.RUNNER_NAME!=='dg-sites-vps-01-duindorphalloweenstg-01'
 ||execFileSync('id',['-un'],{encoding:'utf8'}).trim()!=='duindorphalloweenstg'
 ||!workspace?.startsWith(join(runner,'_work')+sep)||!['inspect','clear-build-cache','compact-git-checkout'].includes(action))throw new Error('STAGING_RUNNER_BOUNDARY_REQUIRED');
const resolvedWorkspace=await realpath(workspace);
if(!resolvedWorkspace.startsWith(join(runner,'_work')+sep))throw new Error('WORKSPACE_SYMLINK_OUTSIDE_RUNNER');
const caches=[join(workspace,'.next/cache'),join(workspace,'node_modules/.cache')];
async function present(path){try{return await lstat(path);}catch(error){if(error.code==='ENOENT')return null;throw error;}}
function measure(command,args){console.log(execFileSync(command,args,{encoding:'utf8',timeout:180000,maxBuffer:2*1024*1024}).trim());}
measure('df',['-h',root]);
for(const directory of [join(runner,'_work'),workspace,join(root,'releases')])if(await present(directory))measure('du',['-xhd1',directory]);
for(const path of caches)if(await present(path))measure('du',['-xsh',path]);
const git=(args)=>execFileSync('git',['-C',workspace,...args],{encoding:'utf8',timeout:480000,maxBuffer:2*1024*1024}).trim();
measure('du',['-xhd1',join(workspace,'.git')]);
console.log(git(['count-objects','-vH']));
if(action==='compact-git-checkout'){
 if(git(['rev-parse','HEAD'])!==process.env.GITHUB_SHA||git(['rev-parse','--is-shallow-repository'])!=='true')throw new Error('EXACT_SHALLOW_CHECKOUT_REQUIRED');
 if(spawnSync('git',['-C',workspace,'show-ref','--verify','--quiet','refs/stash']).status===0
  ||git(['worktree','list','--porcelain']).split('\n').filter(line=>line.startsWith('worktree ')).length!==1)throw new Error('PRESERVE_LOCAL_RECOVERY_REFERENCES');
 const reachable=Number(git(['rev-list','--disk-usage','--objects','--all']));
 const before=await statfs(root),available=before.bavail*before.bsize;
 if(!Number.isSafeInteger(reachable)||reachable<0||available<reachable*2+1024**3)throw new Error('INSUFFICIENT_SPACE_FOR_SAFE_GIT_REPACK');
 console.log(JSON.stringify({reachableCompressedBytes:reachable,availableBytes:available}));
 git(['reflog','expire','--expire=now','--all']);
 git(['-c','pack.threads=1','-c','pack.windowMemory=32m','gc','--prune=now']);
 if(git(['rev-parse','HEAD'])!==process.env.GITHUB_SHA)throw new Error('CHECKOUT_CHANGED_DURING_REPACK');
 git(['cat-file','-e','HEAD^{tree}']);
 console.log(git(['count-objects','-vH']));
 console.log('Dedicated staging checkout compacted; exact release revision preserved.');
}
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
