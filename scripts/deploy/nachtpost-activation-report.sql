-- Read-only operational report. Never return addresses, account IDs or preferences.
with event as (
  select id from app_private.events where slug = 'duindorp-halloween-2026'
), batch as (
  select a.minimal_change
  from app_private.audit_events a join event e on e.id = a.event_id
  where a.correlation_id = 'nachtpost-existing-accounts-20260928'
    and a.action = 'newsletter.existing_accounts_activation_completed'
  order by a.id desc limit 1
)
select jsonb_build_object(
  'batchRecorded', exists(select 1 from batch),
  'verifiedAccountsAtActivation', (select minimal_change->'verifiedAccounts' from batch),
  'alreadyActive', (select minimal_change->'alreadyActive' from batch),
  'newlyActivated', (select minimal_change->'activated' from batch),
  'audienceAtActivation', (select minimal_change->'audienceAfter' from batch),
  'audienceNow', (
    select app_private.editorial_audience_counts(id, '{"roles":["subscribers"]}') from event
  ),
  'activationAudits', (
    select count(*) from app_private.audit_events a join event e on e.id = a.event_id
    where a.correlation_id = 'nachtpost-existing-accounts-20260928'
      and a.action = 'newsletter.administratively_activated'
  ),
  'previouslyUnsubscribedAccountsActivated', (
    select count(*) from app_private.audit_events a join event e on e.id = a.event_id
    where a.correlation_id = 'nachtpost-existing-accounts-20260928'
      and a.action = 'newsletter.administratively_activated'
      and a.minimal_change->'previousPreferences'->>'editorial_unsubscribed_at' is not null
  )
) as nachtpost_activation;
