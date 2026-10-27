export async function mailRpc(name, args) {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret || !process.env.NEXT_PUBLIC_SUPABASE_URL) throw new Error('MAIL_SERVICE_CREDENTIALS_MISSING');
  const response = await fetch(`${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).origin}/rest/v1/rpc/${name}`, {method:'POST',headers:{apikey:secret,Authorization:`Bearer ${secret}`,'Content-Type':'application/json','Content-Profile':'api','Accept-Profile':'api'},body:JSON.stringify(args),signal:AbortSignal.timeout(10000)});
  if(!response.ok)throw new Error(`MAIL_RPC_${name}_${response.status}`);
  // PostgREST returns HTTP 204 for successful void RPCs such as bootstrap.
  if(response.status===204)return null;
  return response.json();
}
export async function activeMailConfig() {
  const config = await mailRpc('worker_mail_config',{_environment:process.env.APP_ENVIRONMENT});
  if(!config || !['resend','sendgrid'].includes(config.provider))throw new Error('MAIL_CONFIG_MISSING');
  return config;
}
