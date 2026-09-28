begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(not has_table_privilege('anon','app_private.product_analytics_events','select'),'anonymous users cannot read product analytics');
select ok(not has_table_privilege('authenticated','app_private.product_analytics_events','select'),'signed-in users cannot read actor analytics directly');
select ok(not has_function_privilege('anon','api.analytics_track(text,text,text,uuid,jsonb)','execute'),'anonymous visitors cannot forge authenticated product activity');
select ok(has_function_privilege('authenticated','api.analytics_track(text,text,text,uuid,jsonb)','execute'),'signed-in users can record their own product activity');
select ok(not has_function_privilege('anon','api.admin_product_analytics_snapshot(text,integer)','execute'),'anonymous visitors cannot read organization analytics');
select ok(has_function_privilege('authenticated','api.admin_product_analytics_snapshot(text,integer)','execute'),'the admin analytics contract is callable and capability-guarded');
select ok(not has_function_privilege('authenticated','app_private.analytics_actor(uuid,uuid)','execute'),'identity projection stays private');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.analytics_track('duindorp-halloween-2026','login_completed','participant','96000000-0000-0000-0000-000000000001','{}')$$,'a participant records a successful login');
select lives_ok($$select api.analytics_track('duindorp-halloween-2026','login_completed','participant','96000000-0000-0000-0000-000000000001','{}')$$,'a retried event is idempotent');
select is((select count(*)::integer from app_private.product_analytics_events where event_type='login_completed' and session_id='96000000-0000-0000-0000-000000000001'),1,'the retried login is stored once');
select lives_ok($$select api.analytics_track('duindorp-halloween-2026','environment_opened','participant','96000000-0000-0000-0000-000000000001','{}')$$,'an environment session is recorded');
select lives_ok($$select api.analytics_track('duindorp-halloween-2026','pwa_install_completed','participant','96000000-0000-0000-0000-000000000001','{"platform":"android","displayMode":"browser"}')$$,'a browser-confirmed PWA install is recorded');
select lives_ok($$select api.analytics_track('duindorp-halloween-2026','pwa_standalone_opened','participant','96000000-0000-0000-0000-000000000002','{"platform":"android","displayMode":"standalone"}')$$,'a standalone app session is recorded');
select throws_ok($$select api.analytics_track('duindorp-halloween-2026','environment_opened','participant',gen_random_uuid(),'{"userAgent":"secret"}')$$,'P0001','INVALID_INPUT','unexpected fingerprinting metadata is rejected');
select throws_ok($$select api.analytics_track('duindorp-halloween-2026','made_up','participant',gen_random_uuid(),'{}')$$,'P0001','INVALID_INPUT','unknown product activity is rejected');
select throws_ok($$select api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)$$,'42501','NOT_AUTHORIZED','a participant cannot read the organization dashboard');

select set_config('request.jwt.claims','{"role":"anon"}',true);
select lives_ok($$select api.social_share_track('duindorp-halloween-2026',null,'general_event','native_share_completed','native','96000000-0000-0000-0000-000000000003')$$,'a completed native share is accepted as a distinct event');

insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)
select event.id,'poortenboek.login','child',registration_child.child_id,'{}'
from app_private.events event
cross join lateral (
  select item.child_id from app_private.registration_children item
  where item.event_id=event.id
  order by item.created_at
  limit 1
) registration_child
where event.slug='duindorp-halloween-2026';

insert into auth.audit_log_entries(id,payload,created_at,ip_address)
values(
  '96000000-0000-0000-0000-000000000004',
  '{"action":"login","actor_id":"f0000000-0000-0000-0000-000000000001","actor_username":"admin@example.invalid","traits":{"provider":"email"}}',
  now(),
  ''
);

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)$$,'an event admin reads the statistics snapshot');
select throws_ok($$select api.admin_product_analytics_snapshot('duindorp-halloween-2026',12)$$,'P0001','INVALID_INPUT','unsupported reporting periods are rejected');
select is((api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'summary'->>'pwaInstalled')::integer,1,'the snapshot counts browser-confirmed installs');
select is((api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'summary'->>'pwaStandaloneOpens')::integer,1,'the snapshot counts standalone use separately');
select is((api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'summary'->>'socialShareCompleted')::integer,1,'the snapshot counts completed native shares');
select is((api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'summary'->>'childLogins')::integer,1,'the snapshot counts successful child logins');
select ok((api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'summary'->>'adultLogins')::integer >= 1,'Supabase audit logs provide the successful adult login count');
select ok(exists(
  select 1 from jsonb_array_elements(api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'loginDestinations') metric
  where metric->>'surface'='participant' and (metric->>'count')::integer=1
),'login destinations show an idempotent participant login');
select ok(exists(
  select 1 from jsonb_array_elements(api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'recent') activity
  where activity->>'kind'='auth' and activity->'actor'->>'email'='admin@example.invalid'
),'recent adult activity is attributable to the signed-in account');
select ok(exists(
  select 1 from jsonb_array_elements(api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'recent') activity
  where activity->>'kind'='child' and activity->'actor'->>'name'='Kinderaccount'
),'recent child activity uses a privacy-minimized identity');
select ok(not exists(
  select 1
  from app_private.children child
  where (api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'recent')::text like '%' || child.first_name || '%'
),'no child first name appears in the analytics projection');
select ok(exists(
  select 1 from jsonb_array_elements(api.admin_product_analytics_snapshot('duindorp-halloween-2026',30)->'templates') metric
  where metric->>'templateKey'='general_event' and (metric->>'shared')::integer=1
),'template metrics contain the completed share');

select * from finish();
rollback;
