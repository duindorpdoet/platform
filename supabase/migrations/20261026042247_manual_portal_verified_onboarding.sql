-- A manual concept's named recipient can verify membership before approval.
-- No portal-room/route rights are granted before the normal approval boundary.
create function app_private.portal_invite_available(p app_private.portals,i app_private.portal_team_invites) returns boolean language sql stable security definer set search_path='' as $$
 select p.lifecycle_status<>'archived' and p.approval_status not in ('withdrawn','rejected') and
 (p.approval_status='approved' or (p.record_source='manual' and p.lifecycle_status in ('concept','registered') and exists(
  select 1 from app_private.email_outbox o where o.message_type='portal_manual_instructions' and o.payload->>'portalId'=p.id::text and o.payload->>'inviteId'=i.id::text and lower(o.recipient_email)=i.email)))
$$;
revoke all on function app_private.portal_invite_available(app_private.portals,app_private.portal_team_invites) from public,anon,authenticated;
create or replace function api.portal_invitation_check(_token text,_email text) returns boolean language sql stable security definer set search_path='' as $$
 select length(_token)=64 and exists(select 1 from app_private.portal_team_invites i join app_private.portals p on p.id=i.portal_id where i.token_hash=extensions.digest(_token,'sha256') and i.email=lower(trim(_email)) and i.revoked_at is null and i.accepted_at is null and i.expires_at>now() and app_private.portal_invite_available(p,i))
$$;
create or replace function api.portal_invitation_accept_v1(_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare inv app_private.portal_team_invites; p app_private.portals; uid uuid:=auth.uid(); eid text; owner_id uuid;
begin
 select lower(email) into eid from auth.users where id=uid and email_confirmed_at is not null;
 if eid is null then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501'; end if;
 select * into inv from app_private.portal_team_invites where token_hash=extensions.digest(_token,'sha256');
 select * into p from app_private.portals where id=inv.portal_id for update;
 select * into inv from app_private.portal_team_invites where id=inv.id for update;
 if p.id is null or not app_private.portal_invite_available(p,inv) or inv.email<>eid or inv.revoked_at is not null or inv.accepted_at is not null or inv.expires_at<=now() then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501'; end if;
 if exists(select 1 from app_private.portal_owners where portal_id=p.id and user_id=uid and revoked_at is null) then raise exception 'ALREADY_MEMBER'; end if;
 insert into app_private.portal_owners(portal_id,user_id,role,invited_by,first_name,last_name) values(p.id,uid,inv.role,inv.invited_by,inv.first_name,inv.last_name);
 update app_private.portal_team_invites set accepted_at=now(),accepted_by=uid where id=inv.id;
 select user_id into owner_id from app_private.portal_owners where portal_id=p.id and role='owner' and revoked_at is null;
 perform app_private.poortkamer_email(p.event_id,owner_id,'portal_team_accepted','portal-accepted:'||inv.id,jsonb_build_object('portalCode',p.system_code));
 perform app_private.poortkamer_signal(p.id,'portal.team.accepted',jsonb_build_object('inviteId',inv.id,'userId',uid),'Een nieuwe Poortwachter heeft de sleutel aangenomen.');
 return jsonb_build_object('portalId',p.id);
end $$;
create function api.my_pending_manual_portals(_event_slug text) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name) order by p.system_number),'[]')
 from app_private.portals p join app_private.events e on e.id=p.event_id and e.slug=_event_slug
 join app_private.portal_owners o on o.portal_id=p.id and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null
 where p.record_source='manual' and p.lifecycle_status in ('concept','registered','approved') and p.approval_status not in ('withdrawn','rejected')
$$;
revoke all on function api.my_pending_manual_portals(text) from public,anon;
grant execute on function api.my_pending_manual_portals(text) to authenticated;
revoke all on function api.portal_invitation_accept_v1(text) from public,anon,authenticated;
create or replace function api.portal_invitation_accept(_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; access text;
begin
 select access_level into access from app_private.portal_team_invites where token_hash=extensions.digest(_token,'sha256');
 result:=api.portal_invitation_accept_v1(_token);
 update app_private.portal_owners set access_level=coalesce(access,access_level) where portal_id=(result->>'portalId')::uuid and user_id=auth.uid() and revoked_at is null;
 return result||jsonb_build_object('pendingActivation',exists(select 1 from app_private.portals where id=(result->>'portalId')::uuid and (approval_status<>'approved' or lifecycle_status<>'active')));
end $$;
create or replace function api.worker_manual_portal_instructions(_outbox_id uuid) returns jsonb
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
 'statusText',case when active then 'Bevestig de uitnodiging met hetzelfde e-mailadres om de Poortkamer te openen. Volgens de bestaande teamregel wordt de eerste geverifieerde poortwachter hoofdpoortwachter; als er al een hoofdpoortwachter is, krijg je medebeheer (coadmin).' else 'Deze poort is nog een concept. Bevestig eerst de persoonlijke uitnodiging met hetzelfde e-mailadres. De eerste geverifieerde poortwachter wordt hoofdpoortwachter. De organisatie moet de poort daarna activeren voordat je de Poortkamer kunt openen.' end,
 'actionPath',case when inv.id is not null then '/uitnodiging/poort/'||app_private.poortkamer_invite_token(inv.id) else '/inloggen?next=%2Fomgeving' end);
end $$;
