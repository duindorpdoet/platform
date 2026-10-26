import { management } from "./redesign-preflight.mjs";

// Read only; no contact addresses, invitation tokens or mail contents in logs.
const query = `select coalesce(jsonb_agg(item order by created_at desc),'[]') as manual_portals from (
  select p.created_at, jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,
    'lifecycle',p.lifecycle_status,'approval',p.approval_status,'createdAt',p.created_at,
    'isFinal',p.id=s.final_portal_id,'hasContactEmail',nullif(trim(p.contact_email),'') is not null,
    'owners',(select count(*) from app_private.portal_owners o where o.portal_id=p.id and o.revoked_at is null and o.suspended_at is null),
    'instructions',coalesce((select jsonb_agg(m) from (select status,last_error_code,attempts,next_attempt_at,created_at
      from app_private.email_outbox where message_type='portal_manual_instructions' and payload->>'portalId'=p.id::text order by created_at desc limit 3) m),'[]'),
    'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'accepted',i.accepted_at is not null,'revoked',i.revoked_at is not null,'expiresAt',i.expires_at,
      'recipientVerified',exists(select 1 from auth.users u where lower(u.email)=i.email and u.email_confirmed_at is not null)))
      from app_private.portal_team_invites i where i.portal_id=p.id),'[]')) as item
  from app_private.portals p join app_private.events e on e.id=p.event_id and e.slug='duindorp-halloween-2026'
  left join app_private.event_route_settings s on s.event_id=e.id
  where p.record_source='manual' order by p.created_at desc limit 15
) recent`;
console.log(JSON.stringify(await management("/database/query", { read_only: true, query })));
