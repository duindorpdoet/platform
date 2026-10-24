"use client";
import {createClient} from '@/lib/supabase/client';
export type ReadinessKind='group'|'portal';
export type ReadinessCheck='account_opened'|'tutorial_completed'|'start_time_seen'|'qr_downloaded'|'qr_tested'|'ready_to_host';
export const readinessLabels:Record<ReadinessCheck,string>={account_opened:'Account geopend',tutorial_completed:'Rondleiding afgerond',start_time_seen:'Starttijd bekeken',qr_downloaded:'QR-PDF gemaakt',qr_tested:'Geprinte QR met telefoon getest',ready_to_host:'Klaar om te ontvangen'};
export async function recordReadiness(input:{kind:ReadinessKind;subjectId:string;check:ReadinessCheck;revision?:string|null;source?:'observed'|'manual';detail?:string;attestations?:Record<string,unknown>;done?:boolean;key?:string}) {
  const client=createClient();if(!client)throw new Error('UNAVAILABLE');
  const result=await client.schema('api').rpc('record_evening_readiness',{_subject_type:input.kind,_subject_id:input.subjectId,_check:input.check,_source:input.source??'observed',_expected_revision:input.revision??null,_detail:input.detail??null,_attestations:input.attestations??{},_done:input.done??true,_idempotency_key:input.key??crypto.randomUUID()});
  if(result.error)throw new Error(result.error.message);return result.data;
}
