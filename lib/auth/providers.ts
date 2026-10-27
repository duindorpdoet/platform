import 'server-only';
import {getPublicSupabaseConfig} from '@/lib/config/public-env';
export async function googleAvailability():Promise<boolean|null>{
 const config=getPublicSupabaseConfig();if(!config)return null;
 try{const response=await fetch(`${config.url}/auth/v1/settings`,{headers:{apikey:config.publishableKey},cache:'no-store',signal:AbortSignal.timeout(3000)});return response.ok?(await response.json()).external?.google===true:null;}catch{return null;}
}
