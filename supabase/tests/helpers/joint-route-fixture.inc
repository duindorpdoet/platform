-- Shared synthetic canonical calendar. No persistent production data is used.
\ir registration-management.inc
create function pg_temp.joint_canonical_fixture(_starts timestamptz default '2026-10-31T16:00:00Z') returns jsonb language plpgsql as $$
declare result jsonb:=pg_temp.registration_management_fixture(_starts); eid uuid; point uuid; schedule uuid; gid uuid; n integer:=2;
begin
 select id into eid from app_private.events where slug='duindorp-halloween-2026';
 -- This historical calendar explicitly permits its older early finale slots;
 -- dedicated v3 regressions exercise the new1800-second proposed default.
 update app_private.event_route_settings set max_early_finish_seconds=7200 where event_id=eid;
 -- Keep every seeded family: the remaining two stored start appointments are
 -- separate drafts, alongside the first two immutable published appointments.
 for gid in select id from app_private.walking_groups where id in('23000000-0000-0000-0000-000000000003','23000000-0000-0000-0000-000000000004') order by id loop
  n:=n+1;
  perform app_private.withdraw_group_appointment(gid,'Synthetische oude seedafspraak via bestaande terugtrekflow vervangen door een nieuw concept');
  point:=(api.admin_startregie_start_point_save('duindorp-halloween-2026',null,
   jsonb_build_object('name','Synthetic joint start '||n,'publicLabel','Synthetic joint start '||n,'pointType','gathering','privateAddress','FICTIEF GEZAMENLIJK STARTPUNT '||n,'geocodedLatitude',52.10+n*0.001,'geocodedLongitude',4.27+n*0.001,'publicArrivalInstructions','Synthetische ingang','active',true,'maxGroups',1,'maxChildren',30),null,'Synthetisch startpunt voor gezamenlijk routeonderzoek')->>'id')::uuid;
  perform api.admin_startregie_confirm_point('duindorp-halloween-2026',point,(select version from app_private.start_points where id=point));
  update app_private.event_route_settings set finale_planning_transfer_seconds=n*600 where event_id=eid;
  schedule:=(api.admin_startregie_move_group(gid,point,_starts+make_interval(mins=>(n-1)*10),
   (select version from app_private.walking_groups where id=gid),'neutral','Synthetische conceptafspraak behouden voor gezamenlijk onderzoek')->>'id')::uuid;
  result:=result||jsonb_build_object(case when n=3 then 'third' else 'fourth' end,jsonb_build_object('groupId',gid,'pointId',point,'scheduleId',schedule,'startsAt',_starts+make_interval(mins=>(n-1)*10)));
 end loop;
 update app_private.event_route_settings set finale_planning_transfer_seconds=600 where event_id=eid;
 update app_private.walking_groups set route_mode='dynamic' where event_id=eid;
 update app_private.portal_windows set opens_at=_starts+interval '1 hour' where portal_id='12000000-0000-0000-0000-000000000001';
 return result;
end $$;
create function pg_temp.joint_proposal(_first_arrival timestamptz default null) returns jsonb language plpgsql as $$
declare input jsonb:=api.admin_joint_route_planning_input('duindorp-halloween-2026');groups jsonb:='[]';g jsonb;p jsonb;finale jsonb;win jsonb;final_win jsonb;
 incoming jsonb;outgoing jsonb;visits jsonb;arrival timestamptz;n integer:=0;proposal jsonb;
begin
 select * into p from jsonb_array_elements(input->'portals') item where item->>'id'='12000000-0000-0000-0000-000000000001';win:=p->'windows'->0;
 for g in select * from jsonb_array_elements(input->'groups') order by value->>'id' loop
  arrival:=coalesce(_first_arrival,(select min((item->>'startsAt')::timestamptz)+interval '1 hour' from jsonb_array_elements(input->'groups') item))+make_interval(secs=>n*300);n:=n+1;
  select * into finale from jsonb_array_elements(input->'portals') item where item->>'id'=g#>>'{finale,portalId}';
  select * into final_win from jsonb_array_elements(finale->'windows') w where (g#>>'{finale,reservedAt}')::timestamptz>=(w->>'opensAt')::timestamptz and (g#>>'{finale,reservedAt}')::timestamptz<=(w->>'arrivalClosesAt')::timestamptz limit 1;
  select * into incoming from jsonb_array_elements(input->'legs') leg where leg->>'from'=g->>'startNodeId' and leg->>'to'=p->>'nodeId';
  select * into outgoing from jsonb_array_elements(input->'legs') leg where leg->>'from'=p->>'nodeId' and leg->>'to'=finale->>'nodeId';
  visits:=jsonb_build_array(jsonb_build_object('portalId',p->'id','kind','ordinary','sequence',1,'startsAt',arrival,'visitSeconds',win->'visitSeconds','bufferSeconds',win->'bufferSeconds','walkSeconds',incoming->'seconds','walkMeters',incoming->'meters'),
   jsonb_build_object('portalId',finale->'id','kind','finale','sequence',2,'startsAt',g#>'{finale,reservedAt}','visitSeconds',final_win->'visitSeconds','bufferSeconds',final_win->'bufferSeconds','walkSeconds',outgoing->'seconds','walkMeters',outgoing->'meters'));
  groups:=groups||jsonb_build_array(jsonb_build_object('groupId',g->'id','startsAt',g->'startsAt','finaleArrivalAt',g#>'{finale,reservedAt}',
   'expectedCompletionAt',(g#>>'{finale,reservedAt}')::timestamptz+make_interval(secs=>(final_win->>'visitSeconds')::integer),'visits',visits,'diagnostics','[]'::jsonb));
 end loop;
 proposal:=jsonb_build_object('sourceHash',input->'sourceHash','boardHash',input->'boardHash','policyVersion',input->'policyVersion','valid',true,'groups',groups,'metrics','{}'::jsonb);
 return proposal||jsonb_build_object('proposalHash',app_private.joint_route_proposal_hash(input->>'sourceHash',input->>'boardHash',groups));
end $$;
create function pg_temp.joint_rehash(_proposal jsonb) returns jsonb language sql as $$
 select _proposal||jsonb_build_object('proposalHash',app_private.joint_route_proposal_hash(_proposal->>'sourceHash',_proposal->>'boardHash',_proposal->'groups'))
$$;
