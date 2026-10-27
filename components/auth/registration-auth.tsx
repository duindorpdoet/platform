"use client";
import {useState} from 'react';
import {EmailOtpForm} from './email-otp-form';
import {GoogleAuthButton} from './google-auth-button';
export function RegistrationAuth({googleAvailable}:{googleAvailable:boolean|null}){
 const [busy,setBusy]=useState(false);
 return <EmailOtpForm nextPath="/meelopen" authBusy={busy} alternativeAuth={disabled=><GoogleAuthButton destination="/meelopen" available={googleAvailable} disabled={disabled} onBusyChange={setBusy}/>}/>;
}
