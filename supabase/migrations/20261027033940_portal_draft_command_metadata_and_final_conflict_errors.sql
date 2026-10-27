do $guard$
begin
 if md5(pg_get_functiondef('api.admin_manual_portal_save(text,uuid,jsonb,integer,text)'::regprocedure))
  not in ('d611df9788070918bc140dadf1302c44','b173e2e2a2fe8341cb6e146e62be8b99') then
  raise exception 'UNEXPECTED_PORTAL_SAVE_DEFINITION' using errcode='55000';
 end if;
end
$guard$;

-- A reopened maintenance draft must never replay confirmation or command metadata.
-- PostgREST 14 retries SQLSTATE 40001 indefinitely. Business STALE_VERSION
-- errors return P0001/HTTP 400; the client already handles their message.
CREATE OR REPLACE FUNCTION api.admin_manual_portal_save(_event_slug text, _portal_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; impact jsonb; sensitive boolean; protected boolean; result jsonb; pub record;
begin
 perform 1 from app_private.events where slug=_event_slug for no key update;
 -- The underlying command verifies authorization and the full request hash on replay.
 if _portal_id is null or exists(select 1 from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.manual.save' and idempotency_key=_payload->>'commandKey') then return api.admin_manual_portal_save_before_guard(_event_slug,_portal_id,_payload,_expected_version,_reason); end if;
 select * into p from app_private.portals where id=_portal_id;
 impact:=api.admin_portal_change_impact(_portal_id);
 sensitive:=coalesce(_payload->>'saveMode','')<>'draft' and (
  (coalesce(nullif(_payload->>'lifecycleStatus',''),p.lifecycle_status) is distinct from p.lifecycle_status)
  or (coalesce(nullif(_payload->>'approvalStatus',''),p.approval_status::text) is distinct from p.approval_status::text)
  or (coalesce(nullif(_payload->>'operationStatus',''),p.operation_status::text) is distinct from p.operation_status::text)
  or (_payload ? 'plannedOpensAt' and app_private.parse_amsterdam_instant(_payload->>'plannedOpensAt') is distinct from (select min(opens_at) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'plannedClosesAt' and app_private.parse_amsterdam_instant(_payload->>'plannedClosesAt') is distinct from (select max(closes_at) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'maxGroups' and (_payload->>'maxGroups')::integer is distinct from (select min(max_concurrent_groups) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'maxChildren' and (_payload->>'maxChildren')::integer is distinct from (select min(max_children_per_visit) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'visitMinutes' and (_payload->>'visitMinutes')::integer is distinct from (select min(visit_minutes) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'bufferMinutes' and (_payload->>'bufferMinutes')::integer is distinct from (select min(buffer_minutes) from app_private.portal_windows where portal_id=p.id)));
 protected:=jsonb_array_length(impact->'publishedGroups')>0 or jsonb_array_length(impact->'confirmedGroups')>0 or (impact->>'pendingStops')::integer>0 or (impact->>'reservations')::integer>0;
 if sensitive then
  if (_payload ? 'impactHash' and _payload->>'impactHash' is distinct from impact->>'inputHash') then raise exception 'STALE_VERSION' using errcode='P0001'; end if;
  if protected and (_payload->>'impactHash' is distinct from impact->>'inputHash' or not coalesce((_payload->>'impactConfirmed')::boolean,false)) then raise exception 'CONFIRMATION_REQUIRED' using errcode='23514'; end if;
  if (impact->>'pendingStops')::integer>0 or (impact->>'reservations')::integer>0 then raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 end if;
 result:=api.admin_manual_portal_save_before_guard(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if _payload ? 'contactEmail' and coalesce(_payload->>'saveMode','')<>'draft' and p.contact_email is distinct from nullif(lower(trim(_payload->>'contactEmail')),'') then
  update app_private.portal_team_invites set revoked_at=clock_timestamp() where portal_id=p.id and email=p.contact_email and accepted_at is null and revoked_at is null;
 end if;
 if sensitive and protected then
  for pub in select g.id group_id,publication.starts_at from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) publication where publication.point_snapshot->>'linked_portal_id'=p.id::text loop
   if not exists(select 1 from app_private.portals current join app_private.portal_windows win on win.portal_id=current.id where current.id=p.id and current.lifecycle_status='active' and current.approval_status='approved' and current.operation_status not in ('paused','closed') and pub.starts_at>=win.opens_at and pub.starts_at+make_interval(mins=>win.visit_minutes+win.buffer_minutes)<=win.closes_at) then raise exception 'RESOLVE_ACTIVE_ASSIGNMENTS_FIRST' using errcode='23514'; end if;
  end loop;
 end if;
 return result;
exception when serialization_failure then
 -- A business-version conflict is final. Preserve real serialization failures.
 if sqlerrm = 'STALE_VERSION' then
  raise exception 'STALE_VERSION' using errcode='P0001';
 end if;
 raise;
end $function$
;

create or replace function app_private.strip_portal_draft_command_metadata()
returns trigger
language plpgsql
set search_path=''
as $function$
begin
 new.payload := new.payload - array['impactHash','impactConfirmed','commandKey'];
 return new;
end
$function$;

revoke all on function app_private.strip_portal_draft_command_metadata()
 from public, anon, authenticated;

drop trigger if exists strip_portal_draft_command_metadata
 on app_private.portal_maintenance_drafts;
create trigger strip_portal_draft_command_metadata
before insert or update of payload on app_private.portal_maintenance_drafts
for each row execute function app_private.strip_portal_draft_command_metadata();

-- Remove only transient request metadata. Preserve all editable fields.
update app_private.portal_maintenance_drafts
set payload = payload - array['impactHash','impactConfirmed','commandKey']
where payload ?| array['impactHash','impactConfirmed','commandKey'];

notify pgrst, 'reload schema';
