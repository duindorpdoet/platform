begin;
create extension if not exists pgtap with schema extensions;
select
  no_plan ();
select
  set_config('test.eid', (
      select
        id::text
      from app_private.events
      where
        slug = 'duindorp-halloween-2026'), true);
select
  set_config('test.content', '{"title":"Beveiligd nieuws","intro":"Nieuws voor volwassenen","heroId":"b8200000-0000-0000-0000-000000000001","heroAlt":"Een poort","heroCaption":"","author":"","categoryId":null,"body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"De wijk ontwaakt"}]}]},"cta":null}', true);
insert into app_private.editorial_media (id, event_id, alt, width, height, byte_size, created_by)
  values ('b8200000-0000-0000-0000-000000000001', current_setting('test.eid')::uuid, 'Poort', 1600, 900, 1000, 'f0000000-0000-0000-0000-000000000001');
insert into app_private.push_preferences (user_id, enabled)
  values ('a0000000-0000-0000-0000-000000000001', true)
on conflict (user_id)
  do update set
    enabled = true;
insert into app_private.push_subscriptions (id, user_id, endpoint, p256dh, auth_secret)
select
  ('b8200000-0000-0000-0000-00000000000' || n)::uuid,
  'a0000000-0000-0000-0000-000000000001',
  'https://push.example.invalid/editorial-' || n,
  repeat('a', 32),
  repeat('b', 16)
from
  generate_series(1, 2) n;
insert into app_private.portal_owners (portal_id, user_id, role)
select
  id,
  'a0000000-0000-0000-0000-000000000001',
  'coadmin'
from
  app_private.portals
where
  event_id = current_setting('test.eid')::uuid
  and approval_status = 'approved'
limit 1;
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  api.editorial_preferences_set ('duindorp-halloween-2026', true, true, true);
select
  set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  set_config('test.article', api.admin_news_save ('duindorp-halloween-2026', null, 0, 'private-push-test', current_setting('test.content')::jsonb, '{"parents":{"enabled":true}}')::text, true);
select
  set_config('test.v', current_setting('test.article')::jsonb ->> 'versionId', true);
select
  throws_ok ($$select api.admin_news_save('duindorp-halloween-2026',null,0,'private-push-test',current_setting('test.content')::jsonb)$$, '23505', null, 'duplicate slug rejected');
select
  throws_ok ($$select api.admin_news_save('duindorp-halloween-2026',(current_setting('test.article')::jsonb->>'id')::uuid,0,'private-push-test',current_setting('test.content')::jsonb)$$, '40001', 'STALE_VERSION', 'stale editor cannot overwrite another draft');
select
  api.admin_news_publish (current_setting('test.v')::uuid, jsonb_build_array(jsonb_build_object('channel', 'parents', 'startsAt', now(), 'pushAt', now() + interval '1 hour'), jsonb_build_object('channel', 'houses', 'startsAt', now(), 'pushAt', now() + interval '1 hour')));
set local role postgres;
select
  is ((
      select
        editorial_planning
      from
        app_private.content_versions
      where
        id = current_setting('test.v')::uuid),
      ' {"parents":{"enabled":true}}'::jsonb,
      'draft planning remains stored with the content version');
select
  throws_ok ($$update app_private.content_versions set editorial_planning='{}' where id=current_setting('test.v')::uuid$$, 'P0001', 'IMMUTABLE_VERSION', 'published planning immutable');
select
  is ((
      select
        count(*)::int
      from
        app_private.portal_push_outbox
      where
        news_version_id = current_setting('test.v')::uuid),
      1,
      'overlapping parent and house roles produce one user notification');
select
  is ((
      select
        count(*)::int
      from
        app_private.portal_push_deliveries d
        join app_private.portal_push_outbox n on n.id = d.notification_id
      where
        n.news_version_id = current_setting('test.v')::uuid),
      2,
      'both active devices snapshotted at publication despite delayed push');
select
  set_config('test.n', (
      select
        id::text
      from app_private.portal_push_outbox
      where
        news_version_id = current_setting('test.v')::uuid), true);
select
  is (api.worker_claim_editorial_push (array['parent-a@example.invalid']),
    '[]'::jsonb,
    'planned push not claimed early');
insert into app_private.push_subscriptions (id, user_id, endpoint, p256dh, auth_secret)
  values ('b8200000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'https://push.example.invalid/editorial-3', repeat('a', 32), repeat('b', 16));
select
  api.worker_editorial_tick (false);
select
  is ((
      select
        count(*)::int
      from
        app_private.portal_push_deliveries
      where
        notification_id = current_setting('test.n')::uuid),
      2,
      'new device cannot change the frozen target snapshot');
update
  app_private.portal_push_outbox
set
  available_at = now()
where
  id = current_setting('test.n')::uuid;
select
  is (api.worker_claim_editorial_push (),
    '[]'::jsonb,
    'empty staging allowlist fails closed');
select
  set_config('test.claim', api.worker_claim_editorial_push (array['parent-a@example.invalid'])::text, true);
select
  is (jsonb_array_length(current_setting('test.claim')::jsonb),
    1,
    'allowlisted test account claimed once');
select
  is (jsonb_array_length(current_setting('test.claim')::jsonb -> 0 -> 'targets'),
    2,
    'claim uses immutable device snapshot');
select
  is (api.worker_claim_editorial_push (array['parent-a@example.invalid']),
    '[]'::jsonb,
    'lease prevents duplicate worker claim');
select
  set_config('test.token', current_setting('test.claim')::jsonb -> 0 ->> 'claimToken', true);
select
  throws_ok ($$select api.worker_record_editorial_push(current_setting('test.n')::uuid,gen_random_uuid(),'b8200000-0000-0000-0000-000000000001','sent_to_pushservice')$$, 'P0001', 'STALE_LEASE', 'stale worker receipt denied');
select
  api.worker_record_editorial_push (current_setting('test.n')::uuid, current_setting('test.token')::uuid, 'b8200000-0000-0000-0000-000000000001', 'sent_to_pushservice');
select
  api.worker_record_editorial_push (current_setting('test.n')::uuid, current_setting('test.token')::uuid, 'b8200000-0000-0000-0000-000000000002', 'failed', 'HTTP_503');
select
  api.worker_finish_editorial_push (current_setting('test.n')::uuid, current_setting('test.token')::uuid);
select
  is ((
      select
        count(*)::int
      from
        app_private.portal_push_deliveries
      where
        notification_id = current_setting('test.n')::uuid
        and status = 'sent_to_pushservice'),
      1,
      'partial failure preserves accepted device');
update
  app_private.portal_push_outbox
set
  available_at = now()
where
  id = current_setting('test.n')::uuid;
select
  set_config('test.claim', api.worker_claim_editorial_push (array['parent-a@example.invalid'])::text, true);
select
  is (jsonb_array_length(current_setting('test.claim')::jsonb -> 0 -> 'targets'),
    1,
    'retry only targets failed device');
select
  set_config('test.token', current_setting('test.claim')::jsonb -> 0 ->> 'claimToken', true);
select
  api.worker_record_editorial_push (current_setting('test.n')::uuid, current_setting('test.token')::uuid, 'b8200000-0000-0000-0000-000000000002', 'invalid', 'HTTP_410');
select
  api.worker_finish_editorial_push (current_setting('test.n')::uuid, current_setting('test.token')::uuid);
select
  is ((
      select
        active
      from
        app_private.push_subscriptions
      where
        id = 'b8200000-0000-0000-0000-000000000002'), false, 'expired endpoint deactivated');
select
  ok ((
      select
        completed_at is not null
      from
        app_private.portal_push_outbox
      where
        id = current_setting('test.n')::uuid),
      'terminal devices finish notification');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  api.news_push_clicked (current_setting('test.n')::uuid, 'b8200000-0000-0000-0000-000000000001');
set local role postgres;
select
  is ((
      select
        status
      from
        app_private.portal_push_deliveries
      where
        notification_id = current_setting('test.n')::uuid
        and subscription_id = 'b8200000-0000-0000-0000-000000000001'),
      'sent_to_pushservice',
      'another account cannot forge click');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  api.news_push_clicked (current_setting('test.n')::uuid, 'b8200000-0000-0000-0000-000000000001');
set local role postgres;
select
  is ((
      select
        count(*)::int
      from
        app_private.portal_push_deliveries
      where
        notification_id = current_setting('test.n')::uuid
        and status = 'clicked'),
      1,
      'click counts only the selected device');
select
  ok (not has_table_privilege('authenticated', 'app_private.push_subscriptions', 'select'),
    'subscription endpoints remain private');
select
  ok (not has_function_privilege('anon', 'api.worker_claim_editorial_push(text[])', 'execute'),
    'anon cannot enumerate delivery targets');
-- New campaign is portal-only and has no anonymous projection, including metadata/media.
set local role anon;
select
  set_config('request.jwt.claims', '{"role":"anon"}', true);
select
  is (api.news_feed ('duindorp-halloween-2026', 'website', 'private-push-test'),
    '[]'::jsonb,
    'portal-only article cannot leak through public API');
select
  is (api.editorial_media_access ('b8200000-0000-0000-0000-000000000001'),
    null::jsonb,
    'portal-only image is inaccessible anonymously');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  throws_ok ($$select api.admin_newsletter_save('duindorp-halloween-2026',null,0,'{}','{"roles":["parents"]}')$$, '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot create bulk campaign');
select
  throws_ok ($$select api.admin_newsletter_schedule(gen_random_uuid(),now(),1)$$, '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot send bulk campaign');
select
  *
from
  finish ();
rollback;
