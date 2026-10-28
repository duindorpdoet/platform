// Produces reviewable SQL only. Execute after exact production health and a
// successful canary; IDs must come from a frozen, read-only incident inventory.
export function recoveryQuery(ids, revision, correlationId) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > 10 || new Set(ids).size !== ids.length || ids.some(id => typeof id !== 'string' || !uuid.test(id)) || !uuid.test(correlationId) || !/^[0-9a-f]{40}$/.test(revision)) throw new Error('INVALID_RECOVERY_SCOPE');
  const list = ids.map(id => `'${id}'::uuid`).join(',');
  return `do $recovery$
declare affected integer;
begin
  perform 1 from app_private.email_outbox where id in (${list}) order by id for update;
  if (select count(*) from app_private.email_outbox o where o.id in (${list})
    and o.message_type='group_composition_confirmed' and o.status='unknown'
    and o.last_error_code='WORKER_LEASE_EXPIRED_AFTER_CLAIM' and o.attempts=1
    and o.provider is null and o.provider_id is null and o.accepted_at is null and o.lease_until is null
    and not exists(select 1 from app_private.mail_envelopes e where e.outbox_id=o.id or e.logical_key='mail/'||o.id::text||'/1')
    and not exists(select 1 from app_private.email_events e where e.outbox_id=o.id)) <> ${ids.length}
  then raise exception 'RECOVERY_EVIDENCE_CHANGED'; end if;
  update app_private.email_outbox set status='pending',next_attempt_at=clock_timestamp(),last_error_code=null where id in (${list});
  get diagnostics affected = row_count;
  if affected <> ${ids.length} then raise exception 'RECOVERY_COUNT_CHANGED'; end if;
  insert into app_private.audit_events(event_id,action,resource_type,resource_id,correlation_id,minimal_change)
  select e.id,'mail.worker.recover_unattempted','email_outbox',o.id,'${correlationId}',
    jsonb_build_object('beforeStatus','unknown','afterStatus','pending','previousCode','WORKER_LEASE_EXPIRED_AFTER_CLAIM',
      'attemptsPreserved',1,'proof','NO_GATEWAY_ENVELOPE_OR_PROVIDER_EVENT','release','${revision}')
  from app_private.email_outbox o cross join app_private.events e where o.id in (${list}) and e.slug='duindorp-halloween-2026';
  get diagnostics affected = row_count;
  if affected <> ${ids.length} then raise exception 'RECOVERY_AUDIT_COUNT_CHANGED'; end if;
end $recovery$;
select count(*)::integer as audited from app_private.audit_events where correlation_id='${correlationId}';`;
}
