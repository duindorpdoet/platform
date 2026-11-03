export const FRIGHTNIGHT_STAGING = Object.freeze({
  origin: 'https://staging-halloween.duindorpdoet.nl',
  projectRef: 'nocteiuvohesvqbowchw',
  slug: 'frightnight-2027-test',
});

export function assertFrightnightRelease(env) {
  const target = FRIGHTNIGHT_STAGING;
  if (env.APP_ENVIRONMENT !== 'staging' || env.FRIGHTNIGHT_ENABLED !== 'true'
      || env.APP_URL !== target.origin || env.SUPABASE_PROJECT_REF !== target.projectRef
      || env.FRIGHTNIGHT_PROJECT_REF !== target.projectRef
      || env.NEXT_PUBLIC_SUPABASE_URL !== `https://${target.projectRef}.supabase.co`
      || env.EVENT_SLUG !== target.slug) throw new Error('FRIGHTNIGHT_STAGING_BINDING_REQUIRED');
  if (env.FRIGHTNIGHT_MAIL_MODE !== 'sink' || env.FRIGHTNIGHT_HARDWARE_ENABLED !== 'false') {
    throw new Error('FRIGHTNIGHT_SINK_AND_LOCAL_HARDWARE_REQUIRED');
  }
  if (!['contract', 'mollie'].includes(env.FRIGHTNIGHT_PAYMENT_PROVIDER)) throw new Error('FRIGHTNIGHT_PAYMENT_PROVIDER_REQUIRED');
  if (env.MOLLIE_TEST_API_KEY && !/^test_[A-Za-z0-9]{20,}$/.test(env.MOLLIE_TEST_API_KEY)) throw new Error('FRIGHTNIGHT_LIVE_PAYMENT_FORBIDDEN');
  if (env.FRIGHTNIGHT_PAYMENT_PROVIDER === 'mollie' && !env.MOLLIE_TEST_API_KEY) throw new Error('MOLLIE_TEST_API_KEY_REQUIRED');
  if (env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID)) throw new Error('FRIGHTNIGHT_BOOTSTRAP_ACTOR_INVALID');
  return target;
}

// Metadata and aggregate checks only. Never invokes a worker, asks for OTP,
// impersonates an existing household, reads a secret or creates a test actor.
export const FRIGHTNIGHT_SAFETY_SQL = `select jsonb_build_object(
 'tables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private' and c.relkind='r' and c.relname like 'fn\\_%' escape '\\'),
 'unsafeTables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private' and c.relkind='r' and c.relname like 'fn\\_%' escape '\\' and (not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE'))),
 'unsafeFunctions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where ((n.nspname='app_private' and p.proname like 'fn\\_%' escape '\\') or(n.nspname='api' and p.proname like 'frightnight\\_%' escape '\\')) and (has_function_privilege('anon',p.oid,'EXECUTE') or (p.prosecdef and not exists(select 1 from unnest(p.proconfig) setting where setting in('search_path=""','search_path='))) or (has_function_privilege('authenticated',p.oid,'EXECUTE') and not(coalesce(p.oid=any(array[to_regprocedure('api.frightnight_snapshot(text)'),to_regprocedure('api.frightnight_command(text,text,jsonb,uuid)'),to_regprocedure('api.frightnight_walk(text,uuid)'),to_regprocedure('api.frightnight_admin_list(text,text,integer,integer)'),to_regprocedure('app_private.fn_photo_access(text)')]),false))))),
 'actorFunctions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.oid=any(array[to_regprocedure('api.frightnight_snapshot(text)'),to_regprocedure('api.frightnight_command(text,text,jsonb,uuid)'),to_regprocedure('api.frightnight_walk(text,uuid)'),to_regprocedure('api.frightnight_admin_list(text,text,integer,integer)')]) and has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE')),
 'unsafeEvents',(select count(*) from app_private.fn_events where environment<>'staging' or not is_test),
 'unsafeSink',(select count(*) from app_private.fn_mail_sink where environment<>'staging' or delivery_mode<>'sink'),
 'sinkHasRecipient',exists(select 1 from information_schema.columns where table_schema='app_private' and table_name='fn_mail_sink' and column_name in('recipient','recipient_email','email','to')),
 'legacyBindings',(select count(*) from app_private.fn_events f where exists(select 1 from app_private.registrations r where r.event_id=f.event_id) or exists(select 1 from app_private.walking_groups g where g.event_id=f.event_id) or exists(select 1 from app_private.event_route_settings s where s.event_id=f.event_id and s.planner_mode='dynamic') or exists(select 1 from app_private.duinpad_evenings d where d.event_id=f.event_id)),
 'edition',(select jsonb_build_object('slug',e.slug,'date',e.local_date,'timezone',e.timezone,'phase',e.phase,'environment',f.environment,'isTest',f.is_test,'retentionUntil',f.retention_until) from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug='frightnight-2027-test'),
 'mailWorker',(select jsonb_build_object('active',active,'endpoint',endpoint,'hasSecret',secret_id is not null) from app_private.job_configs where key='mail_outbox'),
 'legacyJobs',(select jsonb_agg(jsonb_build_object('name',jobname,'active',active,'schedule',schedule)) from cron.job where jobname in('duindorp-halloween-route-dispatch','duindorp-poortkamer-maintenance','duindorp-halloween-mail-outbox'))
) as frightnight_safety`;

export function assertFrightnightSafety(safety, requireEdition = true) {
  if (!safety || safety.tables < 20 || safety.unsafeTables !== 0 || safety.unsafeFunctions !== 0 || safety.actorFunctions !== 4
      || safety.unsafeEvents !== 0 || safety.unsafeSink !== 0 || safety.sinkHasRecipient !== false || safety.legacyBindings !== 0) throw new Error('FRIGHTNIGHT_DATABASE_ISOLATION_FAILED');
  const expectedJobs = new Set(['duindorp-halloween-route-dispatch','duindorp-poortkamer-maintenance','duindorp-halloween-mail-outbox']);
  if (!safety.mailWorker?.active || !safety.mailWorker.hasSecret || safety.mailWorker.endpoint !== `${FRIGHTNIGHT_STAGING.origin}/api/jobs/mail`
      || safety.legacyJobs?.length !== expectedJobs.size || safety.legacyJobs.some(job => !expectedJobs.delete(job.name) || !job.active || job.schedule !== '* * * * *')) throw new Error('FRIGHTNIGHT_LEGACY_JOBS_CHANGED');
  if (requireEdition && (!safety.edition || safety.edition.slug !== FRIGHTNIGHT_STAGING.slug || safety.edition.date !== '2027-10-30'
      || safety.edition.timezone !== 'Europe/Amsterdam' || safety.edition.environment !== 'staging' || safety.edition.isTest !== true
      || !Number.isFinite(Date.parse(safety.edition.retentionUntil)))) throw new Error('FRIGHTNIGHT_EDITION_BOOTSTRAP_REQUIRED');
  return safety;
}
