begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(not has_function_privilege('anon','api.portal_team_command(uuid,text,jsonb,uuid)','execute'),'anonymous users cannot manage roles');
select ok(not has_function_privilege('authenticated','api.portal_team_command_before_design(uuid,text,jsonb,uuid)','execute'),'old entrypoint remains private');
select ok(not has_function_privilege('authenticated','app_private.poortkamer_chat_moderator(uuid)','execute'),'permission helper stays private');
select ok(not has_table_privilege('authenticated','app_private.portal_room_messages','select'),'messages are only available through authorized snapshots');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_room_snapshot('duindorp-halloween-2026') is not null;
select set_config('test.team',(select id::text from app_private.portal_room_channels where portal_id='12000000-0000-0000-0000-000000000001' and name='Achter de Poort' and archived_at is null),true);
select set_config('test.community',(select id::text from app_private.portal_room_channels where kind='community' and name='Hulp gevraagd' and archived_at is null limit 1),true);
select set_config('test.announcements',(select id::text from app_private.portal_room_channels where kind='announcements' and archived_at is null limit 1),true);
insert into app_private.portal_owners(portal_id,user_id,role,first_name,last_name) values
 ('12000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','viewer','Mila','Eigen team'),
 ('12000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','coadmin','Sem','Eigen team');
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canModerate','true','primary owner moderates own room');
select is(api.portal_chat_snapshot(current_setting('test.community')::uuid)->>'canModerate','false','owner is not a moderator of the community');
select is(api.portal_chat_snapshot(current_setting('test.announcements')::uuid)->>'canPost','false','owner cannot impersonate organization announcements');
select set_config('test.message',api.portal_chat_send(current_setting('test.team')::uuid,'Een bericht om te modereren',gen_random_uuid(),'12000000-0000-0000-0000-000000000001')->>'id',true);
select set_config('test.public_message',api.portal_chat_send(current_setting('test.community')::uuid,'Een openbaar teamgesprek',gen_random_uuid(),'12000000-0000-0000-0000-000000000001')->>'id',true);
select throws_ok($$select api.portal_chat_action(current_setting('test.community')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.public_message')))$$,'42501','NOT_AUTHORIZED','owner cannot hide community messages');
select lives_ok($$select api.portal_chat_action(current_setting('test.team')::uuid,'pin',jsonb_build_object('messageId',current_setting('test.message'),'pinned',true))$$,'owner pins own team message');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canPin','true','existing coadmin pin right is retained');
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canModerate','false','coadmin does not automatically receive full moderation');
select lives_ok($$select api.portal_chat_action(current_setting('test.team')::uuid,'pin',jsonb_build_object('messageId',current_setting('test.message'),'pinned',false))$$,'coadmin can still unpin');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":true}',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','coadmin cannot delegate moderation');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canModerate','false','viewer starts without moderation');
select throws_ok($$select api.portal_chat_action(current_setting('test.team')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.message')))$$,'42501','NOT_AUTHORIZED','viewer cannot hide messages');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":true}',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','viewer cannot grant themselves moderation');

select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":true}','95000000-0000-0000-0000-000000000001')$$,'owner delegates moderation without changing other roles');
select lives_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":true}','95000000-0000-0000-0000-000000000001')$$,'delegation retry succeeds');
select is((select count(*)::integer from app_private.audit_events where action='portal.team.chat_moderator'),1,'retry creates exactly one audit event');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":false}','95000000-0000-0000-0000-000000000001')$$,'P0001','IDEMPOTENCY_CONFLICT','key cannot be reused for different rights');
select is((select role from app_private.portal_owners where portal_id='12000000-0000-0000-0000-000000000001' and user_id='a0000000-0000-0000-0000-000000000001'),'viewer','moderation does not grant operational or member-management rights');
select is((select m->>'chatModerator' from jsonb_array_elements(api.portal_room_snapshot('duindorp-halloween-2026')->'team') m where m->>'userId'='a0000000-0000-0000-0000-000000000001'),'true','team snapshot projects assigned rights');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":"true"}',gen_random_uuid())$$,'P0001','INVALID_MODERATION','requires a boolean');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"e0000000-0000-0000-0000-000000000001","enabled":false}',gen_random_uuid())$$,'P0001','OWNER_IS_MODERATOR','primary owner keeps moderation');
select throws_ok($$select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000005","enabled":true}',gen_random_uuid())$$,'P0001','MEMBER_NOT_FOUND','cannot grant an unrelated account moderation');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canModerate','true','delegated moderator receives the action controls');
select lives_ok($$select api.portal_chat_action(current_setting('test.team')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.message')))$$,'delegated moderator hides an own-team message');
select ok(api.portal_chat_snapshot(current_setting('test.team')::uuid)::text not like '%Een bericht om te modereren%','hidden body is removed from the projection');
select throws_ok($$select api.portal_chat_action(current_setting('test.community')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.public_message')))$$,'42501','NOT_AUTHORIZED','delegation cannot cross into the community');
select throws_ok($$select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000002')$$,'42501','NOT_AUTHORIZED','moderation does not grant access to another portal');
update app_private.portal_owners set suspended_at=now() where portal_id='12000000-0000-0000-0000-000000000001' and user_id='a0000000-0000-0000-0000-000000000001';
select throws_ok($$select api.portal_chat_snapshot(current_setting('test.team')::uuid)$$,'42501','NOT_AUTHORIZED','suspension also removes chat moderation and reading');
update app_private.portal_owners set suspended_at=null where portal_id='12000000-0000-0000-0000-000000000001' and user_id='a0000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_team_command('12000000-0000-0000-0000-000000000001','chat_moderator','{"userId":"a0000000-0000-0000-0000-000000000001","enabled":false}',gen_random_uuid());
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_chat_snapshot(current_setting('test.team')::uuid)->>'canModerate','false','revoking moderation takes effect immediately');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_chat_snapshot(current_setting('test.community')::uuid)->>'canModerate','true','organization moderates community');
select lives_ok($$select api.portal_chat_action(current_setting('test.community')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.public_message')))$$,'organization hides community messages');
select set_config('test.update',api.portal_chat_send(current_setting('test.announcements')::uuid,'Denk vanavond aan warme kleding.',gen_random_uuid(),null,'{}',false)->>'id',true);
select is(api.admin_portal_room_snapshot('duindorp-halloween-2026')->>'userId','f0000000-0000-0000-0000-000000000001','organizer chat knows its own sender');
select is(jsonb_array_length(api.admin_portal_room_snapshot('duindorp-halloween-2026')->'channels'),3,'organizer sees the two public rooms and announcements');
select is((select string_agg(channel->>'name','|' order by position) from jsonb_array_elements(api.admin_portal_room_snapshot('duindorp-halloween-2026')->'channels') with ordinality item(channel,position) where channel->>'kind'='community'),'Algemeen|Hulp gevraagd','organizer Praatkamer excludes house-only rooms');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_room_snapshot('duindorp-halloween-2026')->'announcements'->0->>'body','Denk vanavond aan warme kleding.','non-urgent updates appear in the owner cockpit');
select is((select count(*)::integer from app_private.portal_push_outbox where kind='urgent'),0,'ordinary update does not become an urgent push');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_chat_action(current_setting('test.announcements')::uuid,'hide',jsonb_build_object('messageId',current_setting('test.update')));
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(jsonb_array_length(api.portal_room_snapshot('duindorp-halloween-2026')->'announcements'),0,'hidden announcements disappear from cockpit too');
select * from finish();
rollback;
