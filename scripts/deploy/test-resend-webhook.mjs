// Real provider test: replay an existing provider-owned event through Resend.
// A fabricated locally signed payload cannot prove provider integration health.
import { mailRpc } from './mail-service.mjs';
for(const name of ['RESEND_ADMIN_API_KEY','RESEND_ACCEPTANCE_EVENT_ID','RESEND_WEBHOOK_ID'])if(!process.env[name])throw new Error(`Provider replay requires ${name}; complete the controlled staging send and record its event first.`);
const response=await fetch(`https://api.resend.com/webhooks/${encodeURIComponent(process.env.RESEND_WEBHOOK_ID)}/events/${encodeURIComponent(process.env.RESEND_ACCEPTANCE_EVENT_ID)}/replay`,{method:'POST',headers:{Authorization:`Bearer ${process.env.RESEND_ADMIN_API_KEY}`,'Content-Type':'application/json'},body:'{}',signal:AbortSignal.timeout(10000)});
if(!response.ok)throw new Error(`RESEND_REPLAY_HTTP_${response.status}`);
const result=await mailRpc('worker_mail_diagnostics',{_environment:process.env.APP_ENVIRONMENT,_event_id:process.env.RESEND_ACCEPTANCE_EVENT_ID});
if(!result.eventLinked)throw new Error('RESEND_WEBHOOK_NOT_CONFIRMED');
console.log('Provider replay queued; the matching event already has a verified durable envelope relation. Real mailbox acceptance remains required.');
