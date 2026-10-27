set lock_timeout = '5s';

create table app_private.account_app_preferences (
 event_id uuid not null references app_private.events(id),
 user_id uuid not null references auth.users(id),
 last_target jsonb,
 welcome_version integer not null default 0 check(welcome_version >= 0),
 welcome_acknowledged_at timestamptz,
 updated_at timestamptz not null default now(),
 primary key(event_id,user_id)
);
create index account_app_preferences_user_idx on app_private.account_app_preferences(user_id);
alter table app_private.account_app_preferences enable row level security;
revoke all on app_private.account_app_preferences from public,anon,authenticated,service_role;

create function api.account_app_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; ctx jsonb; mine jsonb; environments jsonb; children jsonb; pref app_private.account_app_preferences; identity_email text;
begin
 select lower(trim(email)) into identity_email from auth.users where id=actor and email_confirmed_at is not null;
 if actor is null or identity_email is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 ctx:=api.participant_context(_event_slug); eid:=(ctx->'event'->>'id')::uuid;
 if eid is null then raise exception 'EVENT_NOT_FOUND' using errcode='P0001';end if;
 mine:=api.my_context(_event_slug);
 select coalesce(jsonb_agg(item order by case item->>'kind' when 'parent' then 0 when 'house' then 1 else 2 end,item->>'id'),'[]'::jsonb) into environments from (
  select distinct case role->>'key'
   when 'walker' then jsonb_build_object('id','parent','kind','parent','label','Ouder & meeloper','description','Je kinderen, inschrijving, groep, starttijd en route.','path','/omgeving/meeloper/nu')
   when 'homeowner' then jsonb_build_object('id','house:'||(role->>'portalId'),'kind','house','label','Poortwachter','description',coalesce((select p.name from app_private.portals p where p.id=(role->>'portalId')::uuid),'Je Poortkamer, team en verwachte bezoeken.'),'path','/mijn-huis?poort='||(role->>'portalId'))
   when 'viewer' then jsonb_build_object('id','viewer:'||coalesce(role->>'accessId',role->>'groupId'),'kind','viewer','label','Meekijker','description','Volg de voortgang van jouw gekoppelde groep.','path','/omgeving/meekijker/volgen?toegang='||coalesce(role->>'accessId',role->>'groupId'))
  end as item from jsonb_array_elements(ctx->'roles') role
 ) available where item is not null and item->>'id' is not null;
 if exists(select 1 from jsonb_array_elements_text(coalesce(mine->'capabilities','[]'::jsonb)) cap where cap in ('event_admin','registration_manage','portals_manage','groups_manage','live_support','content_manage','content_publish','communications_manage','communications_send')) then
  environments:=environments||jsonb_build_array(jsonb_build_object('id','organization','kind','admin','label','Organisatie','description','Beheer en regie met jouw bestaande bevoegdheden.','path','/admin'));
 end if;
 children:=api.poortenboek_parent(actor,_event_slug,'list');
 select * into pref from app_private.account_app_preferences where event_id=eid and user_id=actor;
 return jsonb_build_object('userId',actor,'email',identity_email,'eventId',eid,'environments',environments,'children',children,
  'resume',case when pref.last_target->>'kind'='adult' and exists(select 1 from jsonb_array_elements(environments) e where e->>'id'=pref.last_target->>'id')
   or pref.last_target->>'kind'='child' and exists(select 1 from jsonb_array_elements(children) c where c->>'id'=pref.last_target->>'id') then pref.last_target else null end,
  'welcomeVersion',coalesce(pref.welcome_version,0));
end $$;

create function api.account_app_command(_event_slug text,_action text,_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; eid uuid; destination text; target jsonb;
begin
 snapshot:=api.account_app_snapshot(_event_slug);eid:=(snapshot->>'eventId')::uuid;
 if _action='remember' then
  target:=jsonb_build_object('kind',_payload->>'kind','id',_payload->>'id');
  if target->>'kind'='adult' then
   select e->>'path' into destination from jsonb_array_elements(snapshot->'environments') e where e->>'id'=target->>'id';
  elsif target->>'kind'='child' then
   if exists(select 1 from jsonb_array_elements(snapshot->'children') c where c->>'id'=target->>'id') then destination:='/poortenboek';end if;
  end if;
  if destination is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  insert into app_private.account_app_preferences(event_id,user_id,last_target) values(eid,auth.uid(),target)
  on conflict(event_id,user_id) do update set last_target=excluded.last_target,updated_at=now();
  return jsonb_build_object('path',destination,'target',target);
 elsif _action='welcome' then
  if (_payload->>'version')::integer is distinct from 1 then raise exception 'WELCOME_VERSION_CHANGED' using errcode='P0001';end if;
  insert into app_private.account_app_preferences(event_id,user_id,welcome_version,welcome_acknowledged_at) values(eid,auth.uid(),1,now())
  on conflict(event_id,user_id) do update set welcome_version=greatest(app_private.account_app_preferences.welcome_version,1),welcome_acknowledged_at=coalesce(app_private.account_app_preferences.welcome_acknowledged_at,now()),updated_at=now();
  return jsonb_build_object('ok',true,'version',1);
 end if;
 raise exception 'INVALID_INPUT' using errcode='P0001';
end $$;
revoke all on function api.account_app_snapshot(text),api.account_app_command(text,text,jsonb) from public,anon,service_role;
grant execute on function api.account_app_snapshot(text),api.account_app_command(text,text,jsonb) to authenticated;

-- Keep existing tour progress/arrival guards; change only the community read contract.
alter function api.participant_guidance(text,text,text,jsonb) rename to participant_guidance_before_account_app;
revoke all on function api.participant_guidance_before_account_app(text,text,text,jsonb) from public,anon,authenticated,service_role;
create function api.participant_guidance(_event_slug text,_action text default 'snapshot',_role text default null,_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; result jsonb; has_admin boolean;
begin
 snapshot:=api.account_app_snapshot(_event_slug);
 has_admin:=exists(select 1 from jsonb_array_elements(snapshot->'environments') e where e->>'kind'='admin');
 begin
  result:=api.participant_guidance_before_account_app(_event_slug,_action,_role,_payload);
 exception when insufficient_privilege then
  if not has_admin or _action not in ('snapshot','acknowledge') then raise;end if;
  result:=jsonb_build_object('userId',auth.uid(),'eventId',snapshot->'eventId','roles','[]'::jsonb,'today',(now() at time zone 'Europe/Amsterdam')::date,'acknowledgedDay',null,'completed','{}'::jsonb,'progress','{}'::jsonb);
 end;
 if has_admin then result:=jsonb_set(result,'{roles}',(result->'roles')||'"admin"'::jsonb);end if;
 if _action='acknowledge' then
  perform api.account_app_command(_event_slug,'welcome','{"version":1}'::jsonb);
  snapshot:=api.account_app_snapshot(_event_slug);
 end if;
 return result||jsonb_build_object('welcomeVersion',snapshot->'welcomeVersion');
end $$;
revoke all on function api.participant_guidance(text,text,text,jsonb) from public,anon,service_role;
grant execute on function api.participant_guidance(text,text,text,jsonb) to authenticated;

-- Minimal device proof: permission alone is never server registration.
create function api.account_push_device(_event_slug text,_endpoint_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; subscription_id uuid;
begin
 snapshot:=api.account_app_snapshot(_event_slug);
 if _endpoint_hash!~'^[a-f0-9]{64}$' then raise exception 'INVALID_INPUT' using errcode='P0001';end if;
 if jsonb_array_length(snapshot->'environments')=0 then return jsonb_build_object('registered',false);end if;
 select s.id into subscription_id from app_private.push_subscriptions s join app_private.push_preferences p on p.user_id=s.user_id and p.enabled
 where s.user_id=auth.uid() and s.active and encode(extensions.digest(s.endpoint,'sha256'),'hex')=_endpoint_hash
 and app_private.valid_push_endpoint(s.endpoint) and app_private.valid_push_keys(s.p256dh,s.auth_secret);
 return jsonb_build_object('registered',subscription_id is not null,'subscriptionId',subscription_id);
end $$;
revoke all on function api.account_push_device(text,text) from public,anon,service_role;
grant execute on function api.account_push_device(text,text) to authenticated;
