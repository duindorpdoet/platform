import { mailRpc } from './mail-service.mjs';
for(const name of ['APP_ENVIRONMENT','SENDGRID_FROM_EMAIL','SENDGRID_FROM_NAME'])if(!process.env[name])throw new Error(`Missing legacy bootstrap value: ${name}`);
// Initial setup retains the effective legacy provider and sender. Subsequent
// deployments do not overwrite or activate central configuration versions.
await mailRpc('worker_mail_bootstrap',{_environment:process.env.APP_ENVIRONMENT,_from_email:process.env.SENDGRID_FROM_EMAIL,_from_name:process.env.SENDGRID_FROM_NAME,_reply_to:process.env.SENDGRID_REPLY_TO||process.env.SENDGRID_FROM_EMAIL});
console.log('Central mail configuration initialized or already present; activation unchanged.');
