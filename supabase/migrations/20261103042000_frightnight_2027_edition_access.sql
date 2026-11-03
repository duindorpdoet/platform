-- Additive private-copy admission. No existing record, identity, payment,
-- outbox, role or legacy event is changed by this migration.
create table app_private.fn_edition_entries (
 event_id uuid not null references app_private.fn_events(event_id),
 user_id uuid not null references auth.users(id),
 expires_at timestamptz not null,
 invitation_digest text not null check(invitation_digest ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 primary key(event_id,user_id),
 check(expires_at>created_at)
);
alter table app_private.fn_edition_entries enable row level security;
revoke all on app_private.fn_edition_entries from public,anon,authenticated,service_role;

create function app_private.fn_actor_active(p_actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select p_actor is not null and exists(select 1 from auth.users u where u.id=p_actor
  and u.email_confirmed_at is not null and u.deleted_at is null
  and (u.banned_until is null or u.banned_until<clock_timestamp()))
$$;
create function app_private.fn_context_allowed(p_event uuid,p_actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select app_private.fn_actor_active(p_actor) and exists(
  select 1 from app_private.events e join app_private.fn_events f on f.event_id=e.id
  where e.id=p_event and f.environment='staging' and f.is_test and (
   e.slug='frightnight-2027-test'
   or exists(select 1 from app_private.fn_edition_entries x where x.event_id=e.id and x.user_id=p_actor and x.expires_at>clock_timestamp())
   or app_private.fn_registration(e.id,p_actor) is not null
   or exists(select 1 from app_private.fn_zones z where z.event_id=e.id and z.owner_id=p_actor)
   or exists(select 1 from app_private.event_capabilities c where c.event_id=e.id and c.user_id=p_actor and c.revoked_at is null)
   or exists(select 1 from app_private.fn_activity_staff s where s.event_id=e.id and s.user_id=p_actor)
  ))
$$;
revoke all on function app_private.fn_actor_active(uuid),app_private.fn_context_allowed(uuid,uuid) from public,anon,authenticated,service_role;

-- Storage evaluates this predicate directly, outside the four guarded RPCs.
-- Keep exact event/zone paths and the owner/capability boundary. An actor may
-- use its upload namespace or the exact currently registered zone photograph,
-- never another uploader's folder. Stale inactive Auth JWTs remain rejected.
create or replace function app_private.fn_photo_access(p_name text) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from app_private.fn_zones z join app_private.fn_events f on f.event_id=z.event_id
  where z.event_id::text=split_part(p_name,'/',1) and z.id::text=split_part(p_name,'/',2)
   and (auth.uid()::text=split_part(p_name,'/',3) or p_name=z.photo_path)
   and f.environment='staging' and f.is_test
   and app_private.fn_context_allowed(z.event_id,auth.uid())
   and (z.owner_id=auth.uid() or app_private.fn_can(z.event_id,'portals_manage',auth.uid())))
$$;
revoke all on function app_private.fn_photo_access(text) from public,anon,service_role;
grant execute on function app_private.fn_photo_access(text) to authenticated;

-- Only the trusted application, after verifying the signed invitation and the
-- actual session actor, can persist this personal entry. It grants no role.
create function api.frightnight_entry_grant(p_slug text,p_actor uuid,p_expires_at timestamptz,p_invitation_digest text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; t timestamptz:=clock_timestamp();
begin
 if not app_private.fn_actor_active(p_actor) then raise exception 'VERIFIED_ACTIVE_ACTOR_REQUIRED' using errcode='42501'; end if;
 if p_expires_at is null or p_expires_at<=t or p_expires_at>t+interval '8 hours'
  or p_invitation_digest is null or p_invitation_digest !~ '^[0-9a-f]{64}$' then raise exception 'INVALID_EDITION_ENTRY' using errcode='22023'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and e.slug<>'frightnight-2027-test' and e.slug like 'frightnight-2027-test-%'
  and f.environment='staging' and f.is_test and not f.closed for update of f;
 if eid is null then raise exception 'OPEN_TEST_COPY_REQUIRED' using errcode='42501'; end if;
 insert into app_private.fn_edition_entries(event_id,user_id,expires_at,invitation_digest)
 values(eid,p_actor,p_expires_at,p_invitation_digest)
 on conflict(event_id,user_id) do update set expires_at=greatest(app_private.fn_edition_entries.expires_at,excluded.expires_at),invitation_digest=excluded.invitation_digest;
 insert into app_private.fn_audit(event_id,actor_id,action,details)
 values(eid,p_actor,'edition.entry_granted',jsonb_build_object('expiresAt',p_expires_at,'purpose','own-registration-only'));
 return jsonb_build_object('granted',true,'slug',p_slug,'expiresAt',p_expires_at);
end $$;
revoke all on function api.frightnight_entry_grant(text,uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function api.frightnight_entry_grant(text,uuid,timestamptz,text) to service_role;

-- Preserve the reviewed core implementation under explicit private ACLs. The
-- public RPC names retain their signatures and now guard every actor request.
alter function api.frightnight_snapshot(text) set schema app_private;
alter function app_private.frightnight_snapshot(text) rename to fn_snapshot_impl;
alter function api.frightnight_command(text,text,jsonb,uuid) set schema app_private;
alter function app_private.frightnight_command(text,text,jsonb,uuid) rename to fn_command_impl;
revoke all on function app_private.fn_snapshot_impl(text),app_private.fn_command_impl(text,text,jsonb,uuid) from public,anon,authenticated,service_role;

create function api.frightnight_snapshot(p_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test;
 if not app_private.fn_context_allowed(eid,actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 return app_private.fn_snapshot_impl(p_slug);
end $$;
create function api.frightnight_command(p_slug text,p_command text,p_payload jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; adult_invite uuid;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_key is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_COMMAND' using errcode='22023'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test for update of f;
 if not app_private.fn_context_allowed(eid,actor) then
  -- A secret adult invitation admits this one consent command, not a new own
  -- registration or a persistent entry. Core consumption creates revocable
  -- household membership, which authorizes the resulting snapshot.
  if app_private.fn_actor_active(actor) and p_command='registration.accept' and p_payload->'consent'='true'::jsonb
   and coalesce(p_payload->>'token','') ~ '^[0-9a-f]{48}$'
   and exists(select 1 from app_private.fn_events where event_id=eid and not closed) then
   select i.id into adult_invite from app_private.fn_registration_invites i
   join app_private.fn_registrations r on r.event_id=i.event_id and r.id=i.registration_id
   where i.event_id=eid and i.token_hash=extensions.digest(p_payload->>'token','sha256')
    and i.expires_at>clock_timestamp() and i.consumed_by is null and i.revoked_at is null
    and r.household_id is not null and r.status not in('cancelled','archived') for update of i;
  end if;
  if adult_invite is null then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 end if;
 return app_private.fn_command_impl(p_slug,p_command,p_payload,p_key);
end $$;
revoke all on function api.frightnight_snapshot(text),api.frightnight_command(text,text,jsonb,uuid) from public,anon,service_role;
grant execute on function api.frightnight_snapshot(text),api.frightnight_command(text,text,jsonb,uuid) to authenticated;

-- Actor bridges use service-role credentials, but an old JWT must not bypass
-- current admission or an Auth ban. Provider bind/confirm/scope/refund-record RPCs remain
-- independent so genuine financial acknowledgements can always reconcile.
create function app_private.fn_require_context(p_slug text,p_actor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test for update of f;
 if not app_private.fn_context_allowed(eid,p_actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
end $$;
revoke all on function app_private.fn_require_context(text,uuid) from public,anon,authenticated,service_role;

alter function api.frightnight_payment_create(text,uuid,uuid) set schema app_private;
alter function app_private.frightnight_payment_create(text,uuid,uuid) rename to fn_payment_create_impl;
revoke all on function app_private.fn_payment_create_impl(text,uuid,uuid) from public,anon,authenticated,service_role;
create function api.frightnight_payment_create(p_slug text,p_actor uuid,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 return app_private.fn_payment_create_impl(p_slug,p_actor,p_key);
end $$;
revoke all on function api.frightnight_payment_create(text,uuid,uuid) from public,anon,authenticated;
grant execute on function api.frightnight_payment_create(text,uuid,uuid) to service_role;

alter function api.frightnight_payment_test_order(text,uuid,uuid,uuid) set schema app_private;
alter function app_private.frightnight_payment_test_order(text,uuid,uuid,uuid) rename to fn_payment_test_order_impl;
revoke all on function app_private.fn_payment_test_order_impl(text,uuid,uuid,uuid) from public,anon,authenticated,service_role;
create function api.frightnight_payment_test_order(p_slug text,p_actor uuid,p_registration uuid,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 return app_private.fn_payment_test_order_impl(p_slug,p_actor,p_registration,p_key);
end $$;
revoke all on function api.frightnight_payment_test_order(text,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function api.frightnight_payment_test_order(text,uuid,uuid,uuid) to service_role;

alter function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) rename to fn_payment_for_refund_impl;
revoke all on function app_private.fn_payment_for_refund_impl(text,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_for_refund(p_slug text,p_actor uuid,p_registration uuid,p_key uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 return app_private.fn_payment_for_refund_impl(p_slug,p_actor,p_registration,p_key,p_reason);
end $$;
revoke all on function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) to service_role;

alter function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) rename to fn_payment_refund_record_impl;
revoke all on function app_private.fn_payment_refund_record_impl(text,uuid,uuid,text,text,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_refund_record(p_slug text,p_actor uuid,p_order_id uuid,p_provider_ref text,p_status text,p_key uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 -- Acknowledgement of an already authorized refund is provider truth. The
 -- private implementation requires its exact persisted actor/order/key/reason
 -- claim and provider binding; later role revocation must not lose that fact.
 return app_private.fn_payment_refund_record_impl(p_slug,p_actor,p_order_id,p_provider_ref,p_status,p_key,p_reason);
end $$;
revoke all on function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) from public,anon,authenticated;
grant execute on function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) to service_role;

alter function api.frightnight_payment_for_actor(text,uuid) set schema app_private;
alter function app_private.frightnight_payment_for_actor(text,uuid) rename to fn_payment_for_actor_impl;
revoke all on function app_private.fn_payment_for_actor_impl(text,uuid) from public,anon,authenticated,service_role;
create function api.frightnight_payment_for_actor(p_slug text,p_actor uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test;
 if not app_private.fn_context_allowed(eid,p_actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 return app_private.fn_payment_for_actor_impl(p_slug,p_actor);
end $$;
revoke all on function api.frightnight_payment_for_actor(text,uuid) from public,anon,authenticated;
grant execute on function api.frightnight_payment_for_actor(text,uuid) to service_role;

alter function api.frightnight_walk(text,uuid) set schema app_private;
alter function app_private.frightnight_walk(text,uuid) rename to fn_walk_impl;
revoke all on function app_private.fn_walk_impl(text,uuid) from public,anon,authenticated,service_role;
create function api.frightnight_walk(p_slug text,p_destination_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid; actor uuid:=auth.uid();
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test;
 if not app_private.fn_context_allowed(eid,actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 return app_private.fn_walk_impl(p_slug,p_destination_id);
end $$;
revoke all on function api.frightnight_walk(text,uuid) from public,anon,service_role;
grant execute on function api.frightnight_walk(text,uuid) to authenticated;

alter function api.frightnight_admin_list(text,text,integer,integer,text,jsonb) set schema app_private;
alter function app_private.frightnight_admin_list(text,text,integer,integer,text,jsonb) rename to fn_admin_list_impl;
revoke all on function app_private.fn_admin_list_impl(text,text,integer,integer,text,jsonb) from public,anon,authenticated,service_role;
create function api.frightnight_admin_list(p_slug text,p_resource text,p_cursor integer default 0,p_limit integer default 50,p_search text default '',p_filters jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid; actor uuid:=auth.uid();
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id
 where e.slug=p_slug and f.environment='staging' and f.is_test;
 if not app_private.fn_context_allowed(eid,actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 return app_private.fn_admin_list_impl(p_slug,p_resource,p_cursor,p_limit,p_search,p_filters);
end $$;
revoke all on function api.frightnight_admin_list(text,text,integer,integer,text,jsonb) from public,anon,service_role;
grant execute on function api.frightnight_admin_list(text,text,integer,integer,text,jsonb) to authenticated;
