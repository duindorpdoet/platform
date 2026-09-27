begin;
create extension if not exists pgtap with schema extensions;
select
  no_plan ();
select
  ok (not has_table_privilege('anon', 'app_private.news_articles', 'select'),
    'news tables are private');
select
  ok (not has_table_privilege('authenticated', 'app_private.newsletter_recipients', 'select'),
    'recipient snapshots are private');
select
  ok (not has_function_privilege('authenticated', 'api.worker_editorial_tick(boolean)', 'execute'),
    'scheduling worker is privileged');
select
  ok (not has_function_privilege('anon', 'api.admin_news_publish(uuid,jsonb)', 'execute'),
    'anonymous publication denied');
select
  ok (not has_function_privilege('authenticated', 'app_private.editorial_audience(uuid,jsonb)', 'execute'),
    'audience internals are private');
select
  ok (not app_private.editorial_rich_valid ('{"type":"doc","content":[{"type":"html","html":"<script>x</script>"}]}'),
    'raw HTML is rejected');
select
  ok (not app_private.editorial_rich_valid ('{"type":"doc","content":[{"type":"text","text":"x","marks":[{"type":"link","attrs":{"href":"javascript:alert(1)"}}]}]}'),
    'unsafe links rejected by SQL');
select
  set_config('test.eid', (
      select
        id::text
      from app_private.events
      where
        slug = 'duindorp-halloween-2026'), true);
select
  set_config('test.content', '{"title":"De nacht komt dichterbij","intro":"Een veilige introductie","heroId":"b8100000-0000-0000-0000-000000000001","heroAlt":"Een verlichte poort","heroCaption":"Onze wijk","author":"Organisatie","categoryId":null,"body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Samen maken we de nacht."}]}]},"cta":{"label":"Lees meer","url":"/verhaal"}}', true);
insert into app_private.editorial_media (id, event_id, alt, width, height, byte_size, created_by)
  values ('b8100000-0000-0000-0000-000000000001', current_setting('test.eid')::uuid, 'Een verlichte poort', 1600, 900, 25000, 'f0000000-0000-0000-0000-000000000001');
-- Parent B acts as a draft-only editor, without publication or send powers.
insert into app_private.event_capabilities (event_id, user_id, capability)
  values (current_setting('test.eid')::uuid, 'a0000000-0000-0000-0000-000000000002', 'content_manage');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select
  set_config('test.created', api.admin_news_save ('duindorp-halloween-2026', null, 0, 'de-nacht', current_setting('test.content')::jsonb)::text, true);
select
  set_config('test.article', (current_setting('test.created')::jsonb ->> 'id'), true);
select
  set_config('test.version', (current_setting('test.created')::jsonb ->> 'versionId'), true);
select
  throws_ok ($$select api.admin_news_publish(current_setting('test.version')::uuid,'[{"channel":"website"}]')$$, '42501', 'NOT_AUTHORIZED', 'draft editor cannot publish');
select
  ok (api.admin_content_snapshot ('duindorp-halloween-2026')::text not like '%' || current_setting('test.version') || '%',
    'legacy content cannot expose editorial drafts');
select
  throws_ok ($$select api.admin_publish_content(current_setting('test.version')::uuid,1,'Dit is een ongeldige omweg')$$, '42501', 'NOT_AUTHORIZED', 'legacy publisher cannot bypass news rights');
set local role anon;
select
  set_config('request.jwt.claims', '{"role":"anon"}', true);
select
  is (api.news_feed ('duindorp-halloween-2026'),
    '[]'::jsonb,
    'draft is not public');
select
  is (api.editorial_media_access ('b8100000-0000-0000-0000-000000000001'),
    null::jsonb,
    'draft image is private');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  lives_ok ($$select api.admin_news_publish(current_setting('test.version')::uuid,jsonb_build_array(jsonb_build_object('channel','website','startsAt',now()),jsonb_build_object('channel','parents','startsAt',now())))$$, 'atomic publication on two channels');
select
  lives_ok ($$select api.admin_news_publish(current_setting('test.version')::uuid,'[]')$$, 'publication retry is idempotent');
select
  lives_ok ($$select api.admin_editorial_snapshot('duindorp-halloween-2026')$$, 'bounded organizer snapshot executes');
set local role anon;
select
  set_config('request.jwt.claims', '{"role":"anon"}', true);
select
  is (jsonb_array_length(api.news_feed ('duindorp-halloween-2026')),
    1,
    'public article visible');
select
  ok (api.editorial_media_access ('b8100000-0000-0000-0000-000000000001') is not null,
    'publicly used image can be displayed');
select
  ok (api.event_public_snapshot ('duindorp-halloween-2026')::text not like '%De nacht komt dichterbij%',
    'legacy public snapshot excludes editorial content');
select
  throws_ok ($$select api.news_feed('duindorp-halloween-2026','parents')$$, '42501', 'NOT_AUTHORIZED', 'anonymous portal feed denied');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  is (jsonb_array_length(api.news_feed ('duindorp-halloween-2026', 'parents')),
    1,
    'parent reads parent publication');
select
  throws_ok ($$select api.news_feed('duindorp-halloween-2026','houses')$$, '42501', 'NOT_AUTHORIZED', 'parent cannot read house feed');
select
  lives_ok ($$select api.news_record(current_setting('test.version')::uuid,'parents','view')$$, 'parent records own read');
select
  is (api.news_feed ('duindorp-halloween-2026', 'parents') -> 0 ->> 'read',
    'true',
    'read status projected per account');
select
  lives_ok ($$select api.editorial_preferences_set('duindorp-halloween-2026',true,true,false)$$, 'explicit adult communication optin');
select
  is (api.editorial_preferences ('duindorp-halloween-2026') ->> 'email',
    'true',
    'newsletter consent retained');
select
  set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  is (jsonb_array_length(api.news_feed ('duindorp-halloween-2026', 'houses')),
    0,
    'unselected house channel has no article');
select
  throws_ok ($$select api.news_feed('duindorp-halloween-2026','parents')$$, '42501', 'NOT_AUTHORIZED', 'house-only account cannot read parent news');
set local role postgres;
select
  throws_ok ($$update app_private.content_versions set structured_content='{}' where id=current_setting('test.version')::uuid$$, 'P0001', 'IMMUTABLE_VERSION', 'published content cannot be changed');
select
  is ((
      select
        count(*)::int
      from
        app_private.news_placements
      where
        version_id = current_setting('test.version')::uuid
        and state = 'live'),
      2,
      'one live placement per selected channel');
set local role authenticated;
select
  set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select
  throws_ok ($$select api.admin_editorial_media_delete('b8100000-0000-0000-0000-000000000001')$$, 'P0001', 'MEDIA_IN_USE', 'used image cannot be deleted');
select
  set_config('test.next', api.admin_news_save ('duindorp-halloween-2026', current_setting('test.article')::uuid, 1, 'de-nacht', jsonb_set(current_setting('test.content')::jsonb, '{title}', '"De nieuwe nacht"'))::text, true);
select
  is (api.news_feed ('duindorp-halloween-2026') -> 0 -> 'content' ->> 'title',
    'De nacht komt dichterbij',
    'new draft leaves live content unchanged');
select
  lives_ok ($$select api.admin_news_publish((current_setting('test.next')::jsonb->>'versionId')::uuid,jsonb_build_array(jsonb_build_object('channel','website','startsAt',now()+interval '1 hour')))$$, 'future publication scheduled');
select
  is (api.news_feed ('duindorp-halloween-2026') -> 0 -> 'content' ->> 'title',
    'De nacht komt dichterbij',
    'scheduled replacement leaves current live until deadline');
set local role postgres;
update
  app_private.news_placements
set
  starts_at = now() - interval '1 second'
where
  version_id = (current_setting('test.next')::jsonb ->> 'versionId')::uuid;
select
  lives_ok ($$select api.worker_editorial_tick(false)$$, 'publication worker advances due items with mail disabled');
select
  lives_ok ($$select api.worker_editorial_tick(false)$$, 'repeated tick is harmless');
set local role authenticated;
select
  is (api.news_feed ('duindorp-halloween-2026') -> 0 -> 'content' ->> 'title',
    'De nieuwe nacht',
    'new version becomes public atomically');
select
  lives_ok ($$select api.admin_newsletter_audience('duindorp-halloween-2026','{"roles":["parents","primary_contacts"]}')$$, 'audience uses existing roles and consent');
select
  is ((api.admin_newsletter_audience ('duindorp-halloween-2026', '{"roles":["parents","primary_contacts"]}') ->> 'recipients')::int,
    1,
    'only explicit optin receives newsletter, overlapping roles deduped');
select
  set_config('test.campaigncontent', jsonb_build_object('internalName', 'Nachtpost test', 'subject', 'De nacht komt dichterbij', 'preheader', 'Nieuws voor de wijk', 'eyebrow', 'NACHTPOST', 'article', current_setting('test.content')::jsonb, 'newsVersionIds', jsonb_build_array((current_setting('test.next')::jsonb ->> 'versionId')), 'closing', 'Tot tussen de poorten', 'senderName', 'Duindorpse Poorten')::text, true);
select
  set_config('test.campaign', api.admin_newsletter_save ('duindorp-halloween-2026', null, 0, current_setting('test.campaigncontent')::jsonb, '{"roles":["parents","primary_contacts"]}')::text, true);
select
  set_config('test.cv', current_setting('test.campaign')::jsonb ->> 'versionId', true);
select
  throws_ok ($$select api.admin_newsletter_schedule(current_setting('test.cv')::uuid,now(),1)$$, 'P0001', 'TEST_MAIL_REQUIRED', 'campaign requires successful test before schedule');
select
  set_config('test.mail', api.admin_newsletter_test (current_setting('test.cv')::uuid, 'b9100000-0000-0000-0000-000000000001')::text, true);
select
  is (api.admin_newsletter_test (current_setting('test.cv')::uuid, 'b9100000-0000-0000-0000-000000000001')::text,
    current_setting('test.mail'),
    'testmail enqueue idempotent');
set local role postgres;
select
  lives_ok ($$select api.worker_newsletter_material(current_setting('test.mail')::uuid)$$, 'worker hydrates testmail without secret token in outbox');
update
  app_private.email_outbox
set
  status = 'accepted'
where
  id = current_setting('test.mail')::uuid;
set local role authenticated;
select
  lives_ok ($$select api.admin_newsletter_preview(current_setting('test.cv')::uuid)$$, 'preview resolves immutable news cards and audience');
select
  lives_ok ($$select api.admin_newsletter_schedule(current_setting('test.cv')::uuid,now(),1)$$, 'scheduling freezes content and recipients');
select
  lives_ok ($$select api.admin_newsletter_schedule(current_setting('test.cv')::uuid,now(),1)$$, 'schedule retry does not duplicate recipients');
select
  throws_ok ($$select api.admin_newsletter_save('duindorp-halloween-2026',(current_setting('test.campaign')::jsonb->>'id')::uuid,1,current_setting('test.campaigncontent')::jsonb,'{"roles":["parents"]}')$$, 'P0001', 'CAMPAIGN_FROZEN', 'scheduled campaign content is immutable');
set local role postgres;
select
  lives_ok ($$select api.worker_editorial_tick(true)$$, 'mail job queues frozen recipients');
select
  lives_ok ($$select api.worker_editorial_tick(true)$$, 'repeated mail job queues no duplicates');
select
  is ((
      select
        count(*)::int
      from
        app_private.newsletter_recipients
      where
        campaign_id = (current_setting('test.campaign')::jsonb ->> 'id')::uuid),
      1,
      'exactly one deduped recipient');
select
  is ((
      select
        count(*)::int
      from
        app_private.email_outbox
      where
        payload ->> 'versionId' = current_setting('test.cv')
        and payload ->> 'test' is distinct from 'true'),
      1,
      'exactly one individual delivery');
select
  set_config('test.recipient', (
      select
        id::text
      from app_private.newsletter_recipients
      where
        campaign_id = (current_setting('test.campaign')::jsonb ->> 'id')::uuid), true);
select
  set_config('test.outbox', (
      select
        outbox_id::text
      from app_private.newsletter_recipients
      where
        id = current_setting('test.recipient')::uuid), true);
update
  app_private.email_outbox
set
  status = 'accepted',
  provider_id = 'provider-fixture'
where
  id = current_setting('test.outbox')::uuid;
select
  is (api.worker_store_email_event ('editorial-processed', current_setting('test.outbox')::uuid, 'processed', now()),
    true,
    'existing SendGrid webhook records processing');
select
  is (api.worker_store_email_event ('editorial-deferred', current_setting('test.outbox')::uuid, 'deferred', now()),
    true,
    'provider deferral recorded');
select
  is ((
      select
        status::text
      from
        app_private.email_outbox
      where
        id = current_setting('test.outbox')::uuid),
      'accepted',
      'provider deferral cannot cause accepted newsletter to resend');
select
  is (api.worker_store_email_event ('editorial-delivered', current_setting('test.outbox')::uuid, 'delivered', now()),
    true,
    'delivery receipt advances status');
select
  is (api.worker_store_email_event ('editorial-delivered', current_setting('test.outbox')::uuid, 'delivered', now()),
    false,
    'duplicate webhook is idempotent');
select
  is ((
      select
        status::text
      from
        app_private.email_outbox
      where
        id = current_setting('test.outbox')::uuid),
      'delivered',
      'provider delivery kept distinct from acceptance');
select
  lives_ok ($$select api.worker_newsletter_unsubscribe(current_setting('test.recipient')::uuid)$$, 'purposebound unsubscribe updates editorial preference');
select
  is (api.worker_newsletter_material ((
      select
        outbox_id
      from app_private.newsletter_recipients
      where
        id = current_setting('test.recipient')::uuid)),
    null::jsonb,
    'optout rechecked immediately before delivery');
set local role authenticated;
select
  is ((api.admin_newsletter_audience ('duindorp-halloween-2026', '{"roles":["parents"]}') ->> 'recipients')::int,
    0,
    'optout excludes future snapshots');
select
  lives_ok ($$select api.admin_editorial_snapshot('duindorp-halloween-2026')$$, 'history and campaign metrics remain bounded and readable');
set local role postgres;
insert into app_private.email_outbox (dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values ('editorial-operational-test', 'registration_received', 'a0000000-0000-0000-0000-000000000001', 'parent-a@example.invalid', '{}');
select
  ok (exists (
      select
        1
      from
        api.worker_claim_outbox (100, 300)
      where
        dedupe_key = 'editorial-operational-test'), 'newsletter optout does not block operational queue');
update
  app_private.email_outbox
set
  status = 'processing',
  lease_until = now() - interval '1 minute'
where
  id = current_setting('test.mail')::uuid;
select
  ok (not exists (
      select
        1
      from
        api.worker_claim_outbox (100, 300)
      where
        id = current_setting('test.mail')::uuid),
      'expired editorial provider lease cannot replay dispatch');
select
  is ((
      select
        status::text
      from
        app_private.email_outbox
      where
        id = current_setting('test.mail')::uuid),
      'unknown',
      'uncertain provider acceptance held for review');
update
  app_private.newsletter_campaigns
set
  status = 'sent',
  updated_at = now() - interval '31 days'
where
  id = (current_setting('test.campaign')::jsonb ->> 'id')::uuid;
update
  app_private.events
set
  local_date = current_date -90
where
  id = current_setting('test.eid')::uuid;
select
  lives_ok ($$select app_private.editorial_retention()$$, 'event retention cleans individual evidence');
select
  is ((
      select
        count(*)::int
      from
        app_private.newsletter_recipients
      where
        campaign_id = (current_setting('test.campaign')::jsonb ->> 'id')::uuid),
      0,
      'recipient email snapshots expire');
select
  is ((
      select
        retained_events ->> 'delivered'
      from
        app_private.newsletter_campaigns
      where
        id = (current_setting('test.campaign')::jsonb ->> 'id')::uuid),
      '1',
      'anonymous delivery totals survive retention');
select
  *
from
  finish ();
rollback;
