-- Reuse verified portal-team invitations; contact data alone never grants membership.
create function app_private.queue_manual_portal_instructions(_portal uuid,_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; inv app_private.portal_team_invites; mailid uuid;
begin
 select * into p from app_private.portals where id=_portal for update;
 if p.contact_email is null then return jsonb_build_object('status','no_email'); end if;
 if p.contact_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'INVALID_EMAIL' using errcode='22023'; end if;
 if p.lifecycle_status='archived' or p.approval_status in ('withdrawn','rejected') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 select * into inv from app_private.portal_team_invites where portal_id=p.id and email=lower(p.contact_email) and accepted_at is null and revoked_at is null and expires_at>now();
 if inv.id is null and not exists(select 1 from app_private.portal_owners o join auth.users u on u.id=o.user_id and lower(u.email)=lower(p.contact_email) where o.portal_id=p.id and o.revoked_at is null and o.suspended_at is null) then
  update app_private.portal_team_invites set revoked_at=now() where portal_id=p.id and email=lower(p.contact_email) and accepted_at is null and revoked_at is null;
  inv.id:=gen_random_uuid();
  insert into app_private.portal_team_invites(id,portal_id,email,first_name,last_name,role,token_hash,invited_by)
  values(inv.id,p.id,lower(p.contact_email),left(coalesce(p.contact_name,'Poortteam'),80),p.system_code,'coadmin',extensions.digest(app_private.poortkamer_invite_token(inv.id),'sha256'),auth.uid()) returning * into inv;
 end if;
 insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 values('manual-portal-instructions:'||p.id||':'||_key,'portal_manual_instructions','manual-portal:'||p.id,lower(p.contact_email),jsonb_build_object('portalId',p.id,'inviteId',inv.id)) on conflict(dedupe_key) do nothing returning id into mailid;
 return jsonb_build_object('status','pending','outboxId',mailid,'inviteId',inv.id);
end $$;
revoke all on function app_private.queue_manual_portal_instructions(uuid,text) from public,anon,authenticated;

alter function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) rename to admin_manual_portal_save_before_instructions;
revoke all on function api.admin_manual_portal_save_before_instructions(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; receipt app_private.command_receipts; result jsonb; hashed text; k text;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 k:=_payload->>'commandKey';hashed:=md5(jsonb_build_array(_event_slug,_portal_id,_payload,_expected_version,_reason)::text);
 if k is not null then
  if length(k) not between 16 and 200 then raise exception 'INVALID_INPUT'; end if;
  select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.manual.save' and idempotency_key=k;
  if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 end if;
 if nullif(trim(_payload->>'contactEmail'),'') is not null and trim(_payload->>'contactEmail') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'INVALID_EMAIL'; end if;
 result:=api.admin_manual_portal_save_before_instructions(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if _portal_id is null then result:=result||jsonb_build_object('instructions',app_private.queue_manual_portal_instructions((result->>'id')::uuid,'welcome')); end if;
 if k is not null then insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.manual.save',k,hashed,result,now()+interval '7 days'); end if;
 return result;
end $$;
revoke all on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;

create function api.admin_manual_portal_instructions(_portal_id uuid,_expected_version integer,_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; receipt app_private.command_receipts; result jsonb; hashed text;
begin
 select * into p from app_private.portals where id=_portal_id;
 if auth.uid() is null or p.id is null or not app_private.has_capability(p.event_id,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=p.event_id for no key update;
 select * into p from app_private.portals where id=_portal_id for update;
 hashed:=md5(jsonb_build_array(_portal_id,_expected_version)::text);
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.instructions' and idempotency_key=_key;
 if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if length(coalesce(_key,'')) not between 16 and 200 then raise exception 'INVALID_INPUT'; end if;
 result:=app_private.queue_manual_portal_instructions(p.id,_key);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.instructions',_key,hashed,result,now()+interval '7 days');
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(p.event_id,auth.uid(),'portal.instructions.queued','portal',p.id,result);
 return result;
end $$;
revoke all on function api.admin_manual_portal_instructions(uuid,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_instructions(uuid,integer,text) to authenticated;

create function api.worker_manual_portal_instructions(_outbox_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o app_private.email_outbox; p app_private.portals; inv app_private.portal_team_invites; active boolean;
begin
 select * into o from app_private.email_outbox where id=_outbox_id and message_type='portal_manual_instructions';
 select * into p from app_private.portals where id=(o.payload->>'portalId')::uuid and contact_email=lower(o.recipient_email) and lifecycle_status<>'archived' and approval_status not in ('withdrawn','rejected');
 if p.id is null then return null; end if;
 active:=p.approval_status='approved' and p.lifecycle_status='active';
 select * into inv from app_private.portal_team_invites where id=(o.payload->>'inviteId')::uuid and portal_id=p.id and email=lower(o.recipient_email) and revoked_at is null and accepted_at is null and expires_at>now();
 if inv.id is null and not exists(select 1 from app_private.portal_owners m join auth.users u on u.id=m.user_id and lower(u.email)=lower(o.recipient_email) where m.portal_id=p.id and m.revoked_at is null and m.suspended_at is null) then return null; end if;
 return jsonb_build_object('portalCode',p.system_code,'portalName',p.name,'contactName',p.contact_name,
 'statusText',case when active then 'Bevestig de uitnodiging met hetzelfde e-mailadres om de Poortkamer te openen. Volgens de bestaande teamregel wordt de eerste geverifieerde poortwachter hoofdpoortwachter; als er al een hoofdpoortwachter is, krijg je medebeheer (coadmin).' else 'Deze poort is nog een concept. De organisatie moet de poort eerst activeren. Daarna kun je de uitnodiging met hetzelfde e-mailadres bevestigen en de Poortkamer openen.' end,
 'actionPath',case when active and inv.id is not null then '/uitnodiging/poort/'||app_private.poortkamer_invite_token(inv.id) else '/inloggen?next=%2Fomgeving' end);
end $$;
revoke all on function api.worker_manual_portal_instructions(uuid) from public,anon,authenticated;
grant execute on function api.worker_manual_portal_instructions(uuid) to service_role;

alter function api.admin_portal_editor_snapshot(text) rename to admin_portal_editor_snapshot_before_instructions;
revoke all on function api.admin_portal_editor_snapshot_before_instructions(text) from public,anon,authenticated;
create function api.admin_portal_editor_snapshot(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.admin_portal_editor_snapshot_before_instructions(_event_slug);
 return jsonb_set(result,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object('instructionStatus',(select case when i.accepted_at is null and i.expires_at<=now() then 'expired' else o.status::text end from app_private.email_outbox o left join app_private.portal_team_invites i on i.id=(o.payload->>'inviteId')::uuid where o.message_type='portal_manual_instructions' and o.payload->>'portalId'=item->>'id' order by o.created_at desc limit 1)) order by ord) from jsonb_array_elements(result->'portals') with ordinality t(item,ord)),'[]'));
end $$;
revoke all on function api.admin_portal_editor_snapshot(text) from public,anon;
grant execute on function api.admin_portal_editor_snapshot(text) to authenticated;
