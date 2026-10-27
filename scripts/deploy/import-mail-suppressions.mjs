// Input: reviewed SendGrid export normalized to [{email,reason}], with reason
// bounce|spamreport|unsubscribe|invalid. No raw addresses are sent to the RPC.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { mailRpc } from './mail-service.mjs';
const filename=process.argv[2];
if(!filename||process.argv[3]!=='--confirm-complete-export')throw new Error('Usage: import-mail-suppressions.mjs <reviewed-private-export.json> --confirm-complete-export');
if(!['staging','production'].includes(process.env.APP_ENVIRONMENT))throw new Error('Explicit environment required');
const bytes=await readFile(filename),entries=JSON.parse(bytes),hash=createHash('sha256').update(bytes).digest('hex');
if(!Array.isArray(entries))throw new Error('Export must be an array');
const rows=entries.map(entry=>{
 if(typeof entry.email!=='string'||!/^\S+@\S+\.\S+$/.test(entry.email)||!['bounce','spamreport','unsubscribe','invalid'].includes(entry.reason))throw new Error('Invalid suppression export entry');
 return {emailHash:createHash('sha256').update(entry.email.trim().toLowerCase()).digest('hex'),reason:entry.reason};
});
for(let offset=0;offset<rows.length;offset+=500)await mailRpc('worker_import_mail_suppressions',{_environment:process.env.APP_ENVIRONMENT,_entries:rows.slice(offset,offset+500),_source_hash:hash,_complete:false});
await mailRpc('worker_import_mail_suppressions',{_environment:process.env.APP_ENVIRONMENT,_entries:[],_source_hash:hash,_complete:true});
console.log(`Reviewed suppression import completed (${rows.length} entries). No consent was restored.`);
