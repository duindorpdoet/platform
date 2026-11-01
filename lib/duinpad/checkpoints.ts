import 'server-only';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { serverEnv } from '@/lib/config/server-env';
import { createPrivilegedClient } from '@/lib/supabase/privileged';
import { authenticatedClient, portalPrint } from '@/lib/redesign/server';
import { decryptValue, encryptValue, secretBytes } from '@/lib/poortenboek/crypto';
import { ApiError } from '@/lib/http/api';
export type CheckpointCard={id:string;checkpointId?:string;portalId?:string;label:string;instruction:string;version:number;ciphertext?:string};
type Panel={eventId:string;eventDate:string;qr1:CheckpointCard|null;qr2:CheckpointCard|null;portals:Array<{id:string;label:string}>};
function key(){return createHmac('sha256',secretBytes(serverEnv().CHILD_CODE_ENCRYPTION_KEY)).update('duinpad-checkpoint-print-v1').digest('base64');}
export async function checkpointPanel(action='read',data:Record<string,unknown>={}):Promise<Panel>{
 const {actor}=await authenticatedClient(),client=createPrivilegedClient();if(!client)throw new ApiError(503,'UNAVAILABLE','Het beheer is even niet beschikbaar.');
 if(action==='create'||action==='rotate'){
  const credential=randomBytes(32).toString('hex'),shortCode=randomBytes(6).toString('hex').toUpperCase();
  data={...data,ciphertext:encryptValue(JSON.stringify({credential,shortCode}),key(),`duinpad-qr1:${serverEnv().EVENT_SLUG}`),tokenHash:createHash('sha256').update(credential).digest('hex'),shortHash:createHash('sha256').update(shortCode).digest('hex')};
 }
 const {data:result,error}=await client.schema('api').rpc('duinpad_checkpoint_admin',{_event_slug:serverEnv().EVENT_SLUG,_actor:actor,_action:action,_data:data});
 if(error)throw new ApiError(error.code==='42501'?403:409,'CHECKPOINT_UNAVAILABLE',error.code==='42501'?'Je hebt geen toegang tot het Duinpadbeheer.':'De koppeling is gewijzigd of ontbreekt. Haal de actuele gegevens op.');return result;
}
export function safePanel(panel:Panel){if(!panel.qr1)return panel;const safe={...panel.qr1};delete safe.ciphertext;return {...panel,qr1:safe};}
export async function checkpointPoster(stage:'qr1'|'qr2'){
 const panel=await checkpointPanel(),card=panel[stage];if(!card)throw new ApiError(409,'NOT_CONFIGURED','Nog niet ingesteld. Koppel eerst het juiste checkpoint.');
 if(card.portalId){const material=await portalPrint(card.portalId);return {...card,ciphertext:undefined,credential:material.credential,shortCode:material.shortCode,origin:material.origin,eventDate:material.eventDate,credentialRevision:material.credentialRevision};}
 try{const material=JSON.parse(decryptValue(card.ciphertext!,key(),`duinpad-qr1:${serverEnv().EVENT_SLUG}`));if(!/^[a-f0-9]{64}$/.test(material.credential)||!/^[A-F0-9]{12}$/.test(material.shortCode))throw Error();return {...card,ciphertext:undefined,credential:material.credential as string,shortCode:material.shortCode as string,origin:new URL(serverEnv().APP_URL).origin,credentialRevision:card.version,eventDate:panel.eventDate};}catch{throw new ApiError(503,'PRINT_UNAVAILABLE','De bestaande code kon niet veilig worden opgehaald. Vraag de organisatie om herstelcontrole.');}
}
