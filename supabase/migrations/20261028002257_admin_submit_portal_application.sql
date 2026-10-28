-- Organization submission is a separate command: the actor never becomes the applicant.
-- Keep the relaxed resident submit contract separate from approval requirements.
create function app_private.portal_submission_validation(_event_id uuid, _draft jsonb, _verified_email text)
returns jsonb language plpgsql stable set search_path='' as $$
declare world_id uuid; missing jsonb; postal text := upper(replace(trim(coalesce(_draft #>> '{address,postalCode}','')),' ',''));
begin
 select w.id into world_id from app_private.worlds w where w.event_id=_event_id and w.slug=lower(trim(_draft->>'requestedWorldSlug'));
 select coalesce(jsonb_agg(jsonb_build_object('field',field,'message',message,'repair',repair)),'[]'::jsonb) into missing
 from (values
 ('email','Laat de bewoner het eigen e-mailadres bevestigen; het aanvraagadres moet daarmee overeenkomen.','identity',_verified_email is null or lower(trim(coalesce(_draft->>'email','')))<>_verified_email),
 ('contactName','Vul een contactnaam van 2–120 tekens in.','edit',length(trim(coalesce(_draft->>'contactName',''))) not between 2 and 120),
 ('phone','Vul een telefoonnummer van 6–32 tekens in.','edit',length(trim(coalesce(_draft->>'phone',''))) not between 6 and 32),
 ('address.street','Corrigeer de straatnaam (2–120 tekens), of laat deze voor indiening leeg.','edit',nullif(trim(_draft #>> '{address,street}'),'') is not null and length(trim(_draft #>> '{address,street}')) not between 2 and 120),
 ('address.houseNumber','Corrigeer het huisnummer (maximaal 12 tekens).','edit',length(trim(coalesce(_draft #>> '{address,houseNumber}','')))>12),
 ('address.addition','Beperk de toevoeging tot 12 tekens.','edit',length(trim(coalesce(_draft #>> '{address,addition}','')))>12),
 ('address.postalCode','Corrigeer de postcode, of laat deze voor indiening leeg.','edit',postal<>'' and postal !~ '^[0-9]{4}[A-Z]{2}$'),
 ('entrance','Beperk de ingangsbeschrijving tot 500 tekens.','edit',length(trim(coalesce(_draft->>'entrance','')))>500),
 ('portalName','Corrigeer de poortnaam (2–120 tekens), of laat deze voor indiening leeg.','edit',nullif(trim(_draft->>'portalName'),'') is not null and length(trim(_draft->>'portalName')) not between 2 and 120),
 ('description','Beperk de beschrijving tot 1.000 tekens.','edit',length(trim(coalesce(_draft->>'description','')))>1000),
 ('intensity','Kies een spanningsniveau van 1 tot en met 4.','edit',coalesce(_draft->>'intensity','') !~ '^[1-4]$'),
 ('requestedWorldSlug','Kies een bestaande wereld van dit evenement.','edit',world_id is null),
 ('availableFrom','Vul een geldige openingstijd in als uu:mm.','edit',coalesce(_draft->>'availableFrom','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
 ('availableUntil','Vul een geldige sluitingstijd in als uu:mm.','edit',coalesce(_draft->>'availableUntil','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
 ('openingTimes','De sluitingstijd moet na de openingstijd liggen.','edit',(_draft->>'availableFrom') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and (_draft->>'availableUntil') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and (_draft->>'availableUntil')<=(_draft->>'availableFrom')),
 ('accessibility','Kies een geldige toegankelijkheidsoptie.','edit',coalesce(_draft->>'accessibility','') not in ('','step_free','steps','mixed','unknown')),
 ('warnings','Leg de waarschuwingen vast in het bestaande bewonersformulier.','resident',coalesce(jsonb_typeof(_draft->'warnings'),'')<>'object')
 ) checks(field,message,repair,invalid) where invalid;
 return jsonb_build_object('worldId',world_id,'missingFields',missing,'policy','resident-submit-relaxed-v1');
end $$;
revoke all on function app_private.portal_submission_validation(uuid,jsonb,text) from public,anon,authenticated;

create function app_private.portal_admin_submission_context(_event_id uuid,_application_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare a app_private.portal_applications; i app_private.portal_registration_intakes; p app_private.portals;
 account_email text; confirmed_at timestamptz; validation jsonb; blockers jsonb; approval jsonb; body jsonb;
begin
 select * into a from app_private.portal_applications where id=_application_id and event_id=_event_id;
 if a.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into i from app_private.portal_registration_intakes where application_id=a.id order by id limit 1;
 select * into p from app_private.portals where application_id=a.id order by id limit 1;
 select lower(trim(u.email)),u.email_confirmed_at into account_email,confirmed_at from auth.users u where u.id=a.applicant_user_id;
 validation:=app_private.portal_submission_validation(_event_id,a.private_draft_data,case when confirmed_at is not null then account_email end);
 blockers:=validation->'missingFields';
 if a.review_status not in ('draft','changes_requested') then blockers:=blockers||jsonb_build_array(jsonb_build_object('field','status','message','Alleen een concept of aanvraag met gevraagde aanpassingen kan worden ingediend.','repair','review')); end if;
 if i.id is not null and (i.event_id<>_event_id or i.claimed_user_id is distinct from a.applicant_user_id or i.claimed_at is null or i.normalized_email is distinct from account_email or i.withdrawn_at is not null)
  or (select count(*) from app_private.portal_registration_intakes where application_id=a.id)>1 then
  blockers:=blockers||jsonb_build_array(jsonb_build_object('field','intake','message','De intake is ingetrokken of niet door deze geverifieerde bewoner geclaimd. Laat de bewoner de bestaande verificatie- of herstartstap uitvoeren.','repair','identity'));
 end if;
 if p.id is not null and (p.event_id<>_event_id or p.lifecycle_status='archived' or p.approval_status in ('withdrawn','rejected')) then
  blockers:=blockers||jsonb_build_array(jsonb_build_object('field','portal','message','De gekoppelde poort is afgesloten, ingetrokken of afgewezen. Gebruik de bestaande beheerprocedure.','repair','review'));
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('field',field,'message',message)),'[]'::jsonb) into approval from (values
 ('address','Vul vóór goedkeuring het volledige adres in.',nullif(trim(a.private_draft_data #>> '{address,street}'),'') is null or nullif(trim(a.private_draft_data #>> '{address,houseNumber}'),'') is null or upper(replace(trim(coalesce(a.private_draft_data #>> '{address,postalCode}','')),' ','')) !~ '^[0-9]{4}[A-Z]{2}$')
 ) requirements(field,message,missing) where missing;
 body:=jsonb_build_object('applicationId',a.id,'code',a.system_code,'version',a.version,'targetStatus','submitted',
  'allowed',jsonb_array_length(blockers)=0,'blockingReasons',blockers,'missingFields',validation->'missingFields','approvalRequirements',approval,
  'contact',jsonb_build_object('name',a.private_draft_data->>'contactName','email',case when confirmed_at is not null then account_email end,'verified',confirmed_at is not null,'matchesApplication',account_email=lower(trim(a.private_draft_data->>'email'))),
  'consent',jsonb_build_object('availability',case when jsonb_typeof(a.private_draft_data->'availability')='boolean' then a.private_draft_data->'availability' end,'locationConsent',case when jsonb_typeof(a.private_draft_data->'locationConsent')='boolean' then a.private_draft_data->'locationConsent' end),
  'statuses',jsonb_build_object('application',jsonb_build_object('id',a.id,'status',a.review_status,'version',a.version),
   'intake',case when i.id is not null then jsonb_build_object('id',i.id,'version',i.version,'claimed',i.claimed_at is not null,'withdrawn',i.withdrawn_at is not null) end,
   'portal',case when p.id is not null then jsonb_build_object('id',p.id,'version',p.version,'lifecycle',p.lifecycle_status,'approval',p.approval_status,'operation',p.operation_status) end),
  'communication',jsonb_build_object('messageType','portal_received','recipientRef',a.applicant_user_id,'recipientEmail',case when confirmed_at is not null then account_email end,'policy','Bestaande outbox en mailbeleid; geen directe verzending'));
 return body||jsonb_build_object('inputHash',encode(extensions.digest(jsonb_build_object('application',to_jsonb(a),'intake',to_jsonb(i),'portal',body#>'{statuses,portal}',
  'account',jsonb_build_object('id',a.applicant_user_id,'email',account_email,'confirmedAt',confirmed_at),'validation',validation,'approval',approval)::text,'sha256'),'hex'));
end $$;
revoke all on function app_private.portal_admin_submission_context(uuid,uuid) from public,anon,authenticated;

create function api.admin_portal_application_submit_preview(_event_slug text,_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if auth.uid() is null or eid is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return app_private.portal_admin_submission_context(eid,_application_id);
end $$;

create function api.admin_portal_application_submit(_event_slug text,_application_id uuid,_expected_version integer,_input_hash text,_reason text,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; actor uuid:=auth.uid(); a app_private.portal_applications; context jsonb;
 saved app_private.command_receipts; request_hash text; result jsonb; receipt_id uuid:=gen_random_uuid();
begin
 -- Match lifecycle commands: event -> capability/key -> intake -> application -> portal -> identity.
 -- No route/planboard computation or provider call is needed for an application submission.
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if actor is null or eid is null or not app_private.has_capability(eid,'portals_manage',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.event_capabilities where event_id=eid and user_id=actor and capability='portals_manage' and revoked_at is null for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _expected_version is null or _expected_version<1 or coalesce(_input_hash,'') !~ '^[a-f0-9]{64}$' or length(trim(coalesce(_reason,''))) not between 10 and 500 or length(coalesce(_idempotency_key,'')) not between 16 and 200 then raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':portal.admin.submit:'||_idempotency_key,0));
 if not exists(select 1 from app_private.portal_applications where id=_application_id and event_id=eid) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.portal_registration_intakes where application_id=_application_id order by id for update;
 select * into a from app_private.portal_applications where id=_application_id and event_id=eid for update;
 perform 1 from app_private.portals where application_id=a.id order by id for share;
 perform 1 from auth.users where id=a.applicant_user_id for share;
 context:=app_private.portal_admin_submission_context(eid,a.id);
 request_hash:=encode(extensions.digest(jsonb_build_array(eid,a.id,_expected_version,_input_hash,trim(_reason))::text,'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=actor and command_type='portal.admin.submit' and idempotency_key=_idempotency_key;
 if saved.id is not null then
  if saved.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
  if saved.safe_result->>'applicantUserId' is distinct from a.applicant_user_id::text or exists(select 1 from jsonb_array_elements(context->'blockingReasons') b where b->>'field' in ('email','intake','portal')) then raise exception 'SUBMISSION_REPLAY_CONTEXT_CHANGED' using errcode='23514'; end if;
  return saved.safe_result;
 end if;
 if a.version<>_expected_version or context->>'inputHash' is distinct from _input_hash then raise exception 'STALE_SUBMISSION_PREVIEW' using errcode='40001'; end if;
 if not (context->>'allowed')::boolean then raise exception 'SUBMISSION_BLOCKED' using errcode='23514',detail=(context->'blockingReasons')::text; end if;
 update app_private.portal_applications set review_status='submitted',requested_world_id=(app_private.portal_submission_validation(eid,a.private_draft_data,context#>>'{contact,email}')->>'worldId')::uuid,
  submitted_at=clock_timestamp(),review_feedback=null,reviewed_by=null,reviewed_at=null,version=version+1 where id=a.id returning * into a;
 insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 values('portal:'||a.id::text||':received:'||a.version::text,'portal_received',a.applicant_user_id::text,context#>>'{contact,email}',jsonb_build_object('applicationId',a.id,'applicationVersion',a.version)) on conflict(dedupe_key) do nothing;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,actor,'portal_application.submitted_by_organization','portal_application',a.id,jsonb_build_object('reason',trim(_reason),'onBehalfOfResident',true,'applicantUserId',a.applicant_user_id,'submittedAt',a.submitted_at,'version',a.version));
 result:=jsonb_build_object('id',a.id,'applicationId',a.id,'applicantUserId',a.applicant_user_id,'status','submitted','version',a.version,'submittedAt',a.submitted_at,'onBehalfOfResident',true,'receiptId',receipt_id);
 insert into app_private.command_receipts(id,actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(receipt_id,actor,'portal.admin.submit',_idempotency_key,request_hash,result,now()+interval '30 days');
 perform realtime.send(jsonb_build_object('resource','portal_registration'),'snapshot_changed','admin-event:'||eid,true);
 return result;
end $$;
revoke all on function api.admin_portal_application_submit_preview(text,uuid),api.admin_portal_application_submit(text,uuid,integer,text,text,text) from public,anon;
grant execute on function api.admin_portal_application_submit_preview(text,uuid),api.admin_portal_application_submit(text,uuid,integer,text,text,text) to authenticated;

-- The existing contact/address approval policy is deliberately unchanged.
alter function api.admin_portal_management_snapshot(text) rename to admin_portal_management_snapshot_before_organization_submit;
revoke all on function api.admin_portal_management_snapshot_before_organization_submit(text) from public,anon,authenticated;
create function api.admin_portal_management_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; eid uuid;
begin
 result:=api.admin_portal_management_snapshot_before_organization_submit(_event_slug);
 select id into eid from app_private.events where slug=_event_slug;
 result:=jsonb_set(result,'{registrations}',coalesce((select jsonb_agg(item||jsonb_build_object('timeline',
  (select coalesce(jsonb_agg(case when entry->>'label'='Klaar voor beoordeling' and exists(select 1 from app_private.audit_events ev
   where ev.event_id=eid and ev.resource_type='portal_application' and ev.resource_id=(item->>'applicationId')::uuid and ev.action='portal_application.submitted_by_organization' and ev.minimal_change->>'submittedAt'=entry->>'at')
   then entry||jsonb_build_object('label','Namens bewoner ingediend door organisatie') else entry end order by pos),'[]'::jsonb) from jsonb_array_elements(item->'timeline') with ordinality t(entry,pos))) order by ord)
  from jsonb_array_elements(result->'registrations') with ordinality rows(item,ord)),'[]'::jsonb));
 return result||jsonb_build_object('canSubmitApplications',app_private.has_capability(eid,'portals_manage',auth.uid()));
end $$;
revoke all on function api.admin_portal_management_snapshot(text) from public,anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;

-- Resident authorization, receipt, mail and actor stay intact; only validation is shared.
CREATE OR REPLACE FUNCTION api.portal_application_submit(_application_id uuid, _expected_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  application app_private.portal_applications;
  actor_email text;
  receipt app_private.command_receipts;
  v_world_id uuid;
  draft jsonb;
begin
  perform app_private.poortkamer_require(p.id,'details') from app_private.portals p where p.application_id=_application_id;
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':portal.submit:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'portal.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into application from app_private.portal_applications
  where id = _application_id and applicant_user_id = actor for update;
  if application.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if application.version <> _expected_version or application.review_status not in ('draft', 'changes_requested') then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  select lower(trim(email)) into actor_email from auth.users where id = actor and email_confirmed_at is not null;
  draft := application.private_draft_data;
  if jsonb_array_length(app_private.portal_submission_validation(application.event_id,draft,actor_email)->'missingFields')>0 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  v_world_id := (app_private.portal_submission_validation(application.event_id,draft,actor_email)->>'worldId')::uuid;

  update app_private.portal_applications
  set review_status = 'submitted', requested_world_id = v_world_id, review_feedback = null,
      submitted_at = now(), reviewed_by = null, reviewed_at = null, version = version + 1
  where id = application.id returning * into application;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'portal:' || application.id::text || ':received:' || application.version::text,
    'portal_received', actor::text, actor_email,
    jsonb_build_object('applicationId', application.id, 'applicationVersion', application.version)
  ) on conflict (dedupe_key) do nothing;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (application.event_id, actor, 'portal_application.submitted', 'portal_application', application.id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'portal.submit', _idempotency_key, _request_hash,
    jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$;
