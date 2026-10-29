-- Release only adds supported commands/readers. No registration, message,
-- publication or operational setting is changed by applying this migration.
set lock_timeout='5s';

-- A household's current assignment is its default walker environment. An
-- independent leader/viewer/portal role remains authorized by its own model.
create or replace function api.participant_context(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; eid uuid; family_group uuid; g uuid; appointment jsonb; item jsonb; roles jsonb:='[]';
begin
 result:=app_private.participant_context_before_start_ops(_event_slug);
 eid:=(result->'event'->>'id')::uuid;
 select a.group_id into family_group from app_private.registrations r
 join app_private.group_registrations a on a.registration_id=r.id and a.superseded_at is null
 join app_private.walking_groups w on w.id=a.group_id and w.event_id=eid and w.retired_at is null
 where r.event_id=eid and r.household_id=app_private.event_registration_household(eid,auth.uid())
  and r.status='submitted' and exists(select 1 from app_private.registration_children c where c.registration_id=r.id and c.participation_status='active')
 order by r.created_at desc,r.id limit 1;
 for item in select value from jsonb_array_elements(coalesce(result->'roles','[]')) loop
  if item->>'key'='walker' and family_group is not null then item:=item||jsonb_build_object('groupId',family_group);end if;
  roles:=roles||jsonb_build_array(item);
 end loop;
 result:=jsonb_set(result,'{roles}',roles);
 select (r->>'groupId')::uuid into g from jsonb_array_elements(roles) r
  where r->>'key' in('walker','viewer') and r->>'groupId' is not null order by case when r->>'key'='walker' then 0 else 1 end limit 1;
 appointment:=app_private.published_start_projection(g);
 if appointment is not null then result:=jsonb_set(result,'{event,startsAt}',appointment->'startsAt',true);end if;
 return result;
end $$;
revoke all on function api.participant_context(text) from public,anon;
grant execute on function api.participant_context(text) to authenticated;

-- Original pending composition messages stay byte-for-byte unchanged. A
-- narrowly authorized compatibility chain preserves their initial intent.
alter function api.worker_group_schedule_mail_payload(uuid) set schema app_private;
alter function app_private.worker_group_schedule_mail_payload(uuid) rename to worker_group_schedule_mail_before_registration_management;
revoke all on function app_private.worker_group_schedule_mail_before_registration_management(uuid) from public,anon,authenticated,service_role;
create function api.worker_group_schedule_mail_payload(_outbox_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare message app_private.email_outbox;
begin
 select * into message from app_private.email_outbox where id=_outbox_id for update;
 if message.message_type is distinct from 'group_composition_confirmed' then
  return app_private.worker_group_schedule_mail_before_registration_management(_outbox_id);
 end if;
 if message.id is null or message.status in('suppressed','delivered','failed') then return null;end if;
 if not exists(select 1 from app_private.group_adult_recipients((message.payload->>'groupId')::uuid) r
  where r.user_id::text=message.recipient_ref and r.email=lower(message.recipient_email)) then return null;end if;
 if not app_private.registration_management_composition_mail_current((message.payload->>'groupId')::uuid,
  message.payload->>'compositionHash',(message.payload->>'compositionRevision')::integer) then return null;end if;
 return message.payload;
end $$;
revoke all on function api.worker_group_schedule_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.worker_group_schedule_mail_payload(uuid) to service_role;

create function api.worker_registration_management_mail_payload(_outbox_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.email_outbox; change app_private.registration_management_changes; r app_private.registrations;
 g app_private.walking_groups; publication app_private.group_start_publications; activation app_private.registration_activations;
 parent_email text; parent_name text; result jsonb; pending boolean; destination text; binding text;
begin
 select * into o from app_private.email_outbox where id=_outbox_id and message_type='registration_group_changed' for update;
 if o.id is null or o.status in('suppressed','delivered','failed') then return null;end if;
 select * into change from app_private.registration_management_changes c where c.registration_id=(o.payload->>'registrationId')::uuid
  and c.action='move' order by c.created_at desc,c.id desc limit 1;
 if change.id is null or change.id::text is distinct from o.payload->>'commandId' then return null;end if;
 select * into r from app_private.registrations where id=change.registration_id and status='submitted';
 if r.id is null or o.recipient_ref is distinct from 'registration:'||r.id then return null;end if;
 if not exists(select 1 from app_private.group_registrations a where a.id=change.group_registration_id
  and a.registration_id=r.id and a.group_id=change.target_group_id and a.superseded_at is null) then return null;end if;
 select * into g from app_private.walking_groups where id=change.target_group_id and event_id=r.event_id and retired_at is null;
 if g.id is null then return null;end if;
 select * into activation from app_private.registration_activations where registration_id=r.id;
 pending:=activation.registration_id is not null and activation.activated_at is null;
 if pending then parent_email:=activation.normalized_email;parent_name:=activation.parent_name;
 else
  select lower(trim(u.email)),app_private.participant_person_name(r.event_id,u.id) into parent_email,parent_name
  from app_private.households h join auth.users u on u.id=h.primary_contact_user_id
  where h.id=r.household_id and u.email_confirmed_at is not null and u.deleted_at is null
   and (u.banned_until is null or u.banned_until<=statement_timestamp())
   and exists(select 1 from app_private.household_members m where m.household_id=h.id and m.user_id=u.id and m.revoked_at is null and m.accepted_at is not null);
 end if;
 if parent_email is null or parent_email is distinct from lower(trim(o.recipient_email)) then return null;end if;
 select * into publication from app_private.current_start_publication(g.id);
 destination:=case when pending then coalesce(app_private.registration_activation_action_path(r.id),
  '/uitnodiging/inschrijving/'||app_private.registration_activation_token(r.id)) else '/omgeving/meeloper/groep' end;
 binding:=encode(extensions.digest(jsonb_build_array(change.id,change.group_registration_id,g.id,parent_email,
  publication.id,publication.starts_at,case when pending then activation.invitation_id end)::text,'sha256'),'hex');
 result:=jsonb_build_object('registrationId',r.id,'registrationReference',r.reference,'personName',parent_name,
  'children',coalesce((select jsonb_agg(c.first_name order by rc.created_at,rc.id) from app_private.registration_children rc
   join app_private.children c on c.id=rc.child_id where rc.registration_id=r.id and rc.participation_status='active'),'[]'),
  'groupId',g.id,'groupName',coalesce(g.display_name,g.system_code),'groupCode',g.system_code,
  'startConfirmed',publication.id is not null,'startsAt',publication.starts_at,'addressReleaseAt',publication.starts_at-interval '1 hour',
  'addressReleased',publication.id is not null and statement_timestamp()>=publication.starts_at-interval '1 hour',
  'activationPending',pending,'actionPath',coalesce(destination,'/mijn-inschrijving'),'registrationBindingHash',binding);
 return result;
end $$;
revoke all on function api.worker_registration_management_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.worker_registration_management_mail_payload(uuid) to service_role;

alter function api.worker_registration_activation_mail_payload(uuid) set schema app_private;
alter function app_private.worker_registration_activation_mail_payload(uuid) rename to worker_registration_activation_before_binding;
revoke all on function app_private.worker_registration_activation_before_binding(uuid) from public,anon,authenticated,service_role;
create function api.worker_registration_activation_mail_payload(_outbox_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; a app_private.registration_activations;
begin
 result:=app_private.worker_registration_activation_before_binding(_outbox_id);
 if result is null then return null;end if;
 select activation.* into a from app_private.registration_activations activation join app_private.email_outbox o
  on o.id=_outbox_id and o.payload->>'registrationId'=activation.registration_id::text;
 return result||jsonb_build_object('registrationBindingHash',encode(extensions.digest(
  jsonb_build_array(a.registration_id,a.invitation_id,a.invitation_version,a.normalized_email,a.activated_at)::text,'sha256'),'hex'));
end $$;
revoke all on function api.worker_registration_activation_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.worker_registration_activation_mail_payload(uuid) to service_role;

-- Revalidate even recovered gateway envelopes. The old prepare path validates
-- the outbox only when first creating an envelope; a stale retry must not send
-- a revoked invitation or a superseded family assignment from stored HTML.
alter function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) set schema app_private;
alter function app_private.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) rename to worker_mail_prepare_before_registration_management;
revoke all on function app_private.worker_mail_prepare_before_registration_management(text,text,uuid,uuid,text,text,text,jsonb,text,text) from public,anon,authenticated,service_role;
create function api.worker_mail_prepare(_environment text,_key text,_config_id uuid,_outbox_id uuid,_channel text,
 _message_type text,_recipient text,_payload jsonb,_payload_hash text,_credential_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.email_outbox; envelope app_private.mail_envelopes; material jsonb; supplied text; existing_binding text;
begin
 perform pg_advisory_xact_lock(hashtextextended(_environment||':'||_key,0));
 select * into envelope from app_private.mail_envelopes where environment=_environment and logical_key=_key for update;
 if envelope.status='accepted' then
  return app_private.worker_mail_prepare_before_registration_management(_environment,_key,_config_id,_outbox_id,_channel,_message_type,_recipient,_payload,_payload_hash,_credential_hash);
 end if;
 select * into o from app_private.email_outbox where id=_outbox_id for update;
 if o.message_type in('registration_activation','registration_group_changed') then
  material:=case when o.message_type='registration_activation' then api.worker_registration_activation_mail_payload(o.id)
   else api.worker_registration_management_mail_payload(o.id) end;
  if material is null or o.status<>'processing' or lower(trim(o.recipient_email)) is distinct from lower(trim(_recipient)) then
   if envelope.id is not null then update app_private.mail_envelopes set status='reconcile',error_code='REGISTRATION_MAIL_SUPERSEDED',lease_until=null where id=envelope.id;end if;
   return jsonb_build_object('dispatch',false,'status','failed','error_code','REGISTRATION_MAIL_SUPERSEDED');
  end if;
  select tag->>'value' into supplied from jsonb_array_elements(coalesce(_payload->'tags','[]')) tag where tag->>'name'='registration_binding';
  select tag->>'value' into existing_binding from jsonb_array_elements(coalesce(envelope.payload->'tags','[]')) tag where tag->>'name'='registration_binding';
  if envelope.id is not null and existing_binding is distinct from material->>'registrationBindingHash' then
   update app_private.mail_envelopes set status='reconcile',error_code='REGISTRATION_MAIL_SUPERSEDED',lease_until=null where id=envelope.id;
   return jsonb_build_object('dispatch',false,'status','failed','error_code','REGISTRATION_MAIL_SUPERSEDED');
  end if;
  if supplied is distinct from material->>'registrationBindingHash' then
   return jsonb_build_object('dispatch',false,'status','deferred','error_code','REGISTRATION_MATERIAL_CHANGED');
  end if;
 end if;
 return app_private.worker_mail_prepare_before_registration_management(_environment,_key,_config_id,_outbox_id,_channel,_message_type,_recipient,_payload,_payload_hash,_credential_hash);
end $$;
revoke all on function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) from public,anon,authenticated;
grant execute on function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) to service_role;
notify pgrst,'reload schema';
