import { activeMailConfig, mailRpc } from './mail-service.mjs';
const config=await activeMailConfig();
if(config.provider==='sendgrid') await import('./diagnose-sendgrid-delivery.mjs');
else {
 const result=await mailRpc('worker_mail_diagnostics',{_environment:process.env.APP_ENVIRONMENT});
 console.log(JSON.stringify({provider:'resend',configVersion:config.version,...result}));
}
