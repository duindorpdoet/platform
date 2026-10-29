-- Provision printable material only when an authorized owner opens the code.
-- Existing hash-only posters remain valid; deployments never rewrite codes.
create or replace function api.portal_print_access(_actor uuid,_portal_id uuid,_action text default 'read',_expected_version integer default null,_ciphertext text default null,_token_hash bytea default null,_short_hash bytea default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals;c app_private.portal_credentials;nextversion integer;may_rotate boolean;
begin
 if _actor is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if _action is null or _action not in('read','ensure','rotate')then raise exception 'INVALID_INPUT'using errcode='22023';end if;
 select *into p from app_private.portals where id=_portal_id;
 if p.id is null or not(exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null)
  or app_private.has_capability(p.event_id,'portals_manage',_actor))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if _action='ensure'then
  select credential.*into c from app_private.portal_credentials credential join app_private.portal_print_material material on material.credential_id=credential.id
   where credential.portal_id=p.id and credential.revoked_at is null and credential.valid_from<=clock_timestamp()and(credential.valid_until is null or credential.valid_until>clock_timestamp())
   order by credential.version desc limit 1;
 end if;
 if _action='rotate'or(_action='ensure'and c.id is null)then
  -- Follow the planning lock order. A print view never changes portal/version
  -- or event policy, and an already provisioned view needs no write locks.
  perform 1 from app_private.events where id=p.event_id for no key update;
  select *into p from app_private.portals where id=_portal_id for update;
  if p.id is null or not(exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null)
   or app_private.has_capability(p.event_id,'portals_manage',_actor))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
  may_rotate:=app_private.has_capability(p.event_id,'portals_manage',_actor)or exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage');
  if _action='rotate'then
   if not may_rotate then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
   if p.version is distinct from _expected_version then raise exception 'STALE_VERSION'using errcode='40001';end if;
  else
   -- Another tab may have provisioned the same portal while we waited.
   select credential.*into c from app_private.portal_credentials credential join app_private.portal_print_material material on material.credential_id=credential.id
    where credential.portal_id=p.id and credential.revoked_at is null and credential.valid_from<=clock_timestamp()and(credential.valid_until is null or credential.valid_until>clock_timestamp())
    order by credential.version desc limit 1;
  end if;
  if _action='rotate'or c.id is null then
   if p.approval_status<>'approved'or p.lifecycle_status='archived'or _ciphertext is null or length(_ciphertext)not between 32 and 4096
    or octet_length(_token_hash)is distinct from 32 or octet_length(_short_hash)is distinct from 32 then raise exception 'INVALID_INPUT'using errcode='22023';end if;
   select coalesce(max(version),0)+1 into nextversion from app_private.portal_credentials where portal_id=p.id;
   if _action='rotate'then update app_private.portal_credentials set revoked_at=clock_timestamp()where portal_id=p.id and revoked_at is null;end if;
   insert into app_private.portal_credentials(portal_id,version,token_hash,short_code_hash,valid_from)
    values(p.id,nextversion,_token_hash,_short_hash,now())returning *into c;
   insert into app_private.portal_print_material(credential_id,ciphertext)values(c.id,_ciphertext);
   if _action='rotate'then update app_private.portals set version=version+1 where id=p.id returning *into p;end if;
   insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(p.event_id,_actor,case when _action='rotate'then 'portal.credential_rotated'else 'portal.print_material_created'end,'portal',p.id,
     jsonb_build_object('credentialVersion',c.version,'reason',case when _action='rotate'then 'Expliciet vernieuwd in QR & printen'else 'Blijvende printcode bij geautoriseerd openen; eerdere posters behouden'end));
  end if;
 elsif _action='read'then
  select *into c from app_private.portal_credentials where portal_id=p.id and revoked_at is null and valid_from<=clock_timestamp()and(valid_until is null or valid_until>clock_timestamp())order by version desc limit 1;
 end if;
 may_rotate:=app_private.has_capability(p.event_id,'portals_manage',_actor)or exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage');
 return jsonb_build_object('credentialId',c.id,'credentialRevision',c.version,'portalVersion',p.version,'canRotate',may_rotate,
  'ciphertext',(select ciphertext from app_private.portal_print_material where credential_id=c.id),
  'legacy',c.id is not null and not exists(select 1 from app_private.portal_print_material where credential_id=c.id),
  'eventDate',(select local_date from app_private.events where id=p.event_id));
end $$;
revoke all on function api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea)from public,anon,authenticated;
grant execute on function api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea)to service_role;
