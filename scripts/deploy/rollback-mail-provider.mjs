import { mailRpc } from './mail-service.mjs';
const revision=Number(process.argv[2]),reason=process.argv[3],confirmed=process.argv[4]==='--confirm-legacy-provider-reviewed';
if(!Number.isSafeInteger(revision)||revision<0||!reason||reason.length<10||!confirmed)throw new Error('Usage: rollback-mail-provider.mjs <expected-revision> <incident-reason> --confirm-legacy-provider-reviewed. Verify retained SendGrid credentials/domain externally first.');
const actor=process.env.MAIL_ROLLBACK_USER_ID;
if(!actor||!(process.env.MAIL_ADMIN_USER_IDS??'').split(',').map(v=>v.trim()).includes(actor))throw new Error('A runtime allowlisted verified MAIL_ROLLBACK_USER_ID is required.');
if(!process.env.SENDGRID_API||!process.env.SEND_EMAIL_HOOK_SECRET)throw new Error('Retained legacy sending and hook credentials are required.');
const result=await mailRpc('mail_admin_rollback',{_environment:process.env.APP_ENVIRONMENT,_actor:actor,_event_slug:process.env.EVENT_SLUG,_expected_revision:revision,_confirmed:true,_reason:reason});
console.log(`Rollback recorded: future envelopes use ${result.active.provider}, config version ${result.active.version}. Existing envelopes, history and suppressions are unchanged.`);
