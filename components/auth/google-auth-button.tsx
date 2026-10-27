"use client";
import {useRef,useState} from 'react';
import {createClient,setAuthReturnDestination,setSessionRememberPreference} from '@/lib/supabase/client';
import {safeReturnPath} from '@/lib/auth/redirect';
export function GoogleAuthButton({destination,available,remember=true,disabled=false,onBusyChange,onStart,beforeRedirect}:{destination:string;available:boolean|null;remember?:boolean;disabled?:boolean;onBusyChange?:(value:boolean)=>void;onStart?:()=>void;beforeRedirect?:()=>void|Promise<void>}){
 const [busy,setBusy]=useState(false),[notice,setNotice]=useState('');const pending=useRef(false);
 async function start(){
  if(pending.current||disabled)return;onStart?.();setNotice('');
  if(available===false){setNotice('Google-aanmelding wordt nog ingericht. Gebruik ondertussen een e-mailcode om bij dezelfde inschrijving te komen.');return;}
  const client=createClient();if(!client){setNotice('De aanmelding is tijdelijk niet bereikbaar. Probeer later opnieuw.');return;}
  pending.current=true;setBusy(true);onBusyChange?.(true);
  try{
   await beforeRedirect?.();setSessionRememberPreference(remember);setAuthReturnDestination(safeReturnPath(destination,'/omgeving/kiezen'));
   const result=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:new URL('/auth/callback',window.location.origin).href,skipBrowserRedirect:true}});
   if(result.error||!result.data.url)throw new Error('OAUTH_UNAVAILABLE');window.location.assign(result.data.url);
  }catch{setNotice('Google-aanmelding kon niet worden gestart. Controleer je verbinding of gebruik een e-mailcode.');pending.current=false;setBusy(false);onBusyChange?.(false);}
 }
 return <><div className="auth-alternative"><span>of</span><button className="auth-google-button" type="button" disabled={disabled||busy} aria-label={busy?'Google openen…':'Doorgaan met Google'} aria-busy={busy} title="Doorgaan met Google" onClick={()=>void start()}><svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24"><path fill="#4285F4" d="M21.6 12.23c0-.71-.06-1.39-.18-2.05H12v3.88h5.38a4.6 4.6 0 0 1-2 3.02v2.51h3.24c1.89-1.74 2.98-4.31 2.98-7.36Z"/><path fill="#34A853" d="M12 22c2.7 0 4.96-.9 6.62-2.41l-3.24-2.51c-.9.6-2.05.96-3.38.96-2.61 0-4.82-1.76-5.61-4.12H3.05v2.59A10 10 0 0 0 12 22Z"/><path fill="#FBBC05" d="M6.39 13.92a6 6 0 0 1 0-3.84V7.49H3.05a10 10 0 0 0 0 9.02l3.34-2.59Z"/><path fill="#EA4335" d="M12 5.96c1.47 0 2.79.5 3.82 1.49l2.86-2.87A9.6 9.6 0 0 0 12 2a10 10 0 0 0-8.95 5.49l3.34 2.59A5.99 5.99 0 0 1 12 5.96Z"/></svg></button></div>{notice&&<p className="entry-error auth-alternative-error" role="alert">{notice}</p>}</>;
}
