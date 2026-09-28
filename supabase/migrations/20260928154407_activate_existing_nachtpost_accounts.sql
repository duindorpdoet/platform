-- One-time administrative enrollment requested by the organization on 2026-09-28.
-- This records an organization action, never a claim that a user opted in.
-- No mail, campaign, push setting, account or provider suppression is created.
-- A single DO statement is atomic, including its completion marker and audits.
do $$
declare
  target_event uuid;
  changed_count integer;
  account_count integer;
  prior_active_count integer;
  audience jsonb;
  batch_id constant text := 'nachtpost-existing-accounts-20260928';
begin
  select id into target_event from app_private.events
  where slug = 'duindorp-halloween-2026';

  -- Empty installations create their event and accounts after migrations.
  if target_event is null then
    raise notice 'Nachtpost activation: no existing event; nothing to activate.';
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(batch_id || target_event::text, 0));
  if exists (
    select 1 from app_private.audit_events
    where event_id = target_event and correlation_id = batch_id
      and action = 'newsletter.existing_accounts_activation_completed'
  ) then
    raise notice 'Nachtpost activation: already completed; later preferences stay unchanged.';
    return;
  end if;

  -- Serialize the short update with account preference changes/unsubscribes.
  -- A preference change submitted afterwards wins and is never re-enrolled.
  lock table app_private.participant_preferences in share row exclusive mode;

  select count(*), count(*) filter (where p.optional_updates_consent)
  into account_count, prior_active_count
  from auth.users u
  left join app_private.participant_preferences p
    on p.event_id = target_event and p.user_id = u.id
  where u.deleted_at is null and not coalesce(u.is_anonymous, false)
    and (u.banned_until is null or u.banned_until <= now())
    and u.email_confirmed_at is not null
    and lower(trim(u.email)) ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$';

  with candidates as materialized (
    select u.id, to_jsonb(p) as previous_preferences
    from auth.users u
    left join app_private.participant_preferences p
      on p.event_id = target_event and p.user_id = u.id
    where u.deleted_at is null and not coalesce(u.is_anonymous, false)
      and (u.banned_until is null or u.banned_until <= now())
      and u.email_confirmed_at is not null
      and lower(trim(u.email)) ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
      and not coalesce(p.optional_updates_consent, false)
  ), activated as (
    insert into app_private.participant_preferences (
      event_id, user_id, optional_updates_consent, editorial_consent_source
    )
    select target_event, id, true, 'organization_activation_20260928'
    from candidates
    on conflict (event_id, user_id) do update set
      optional_updates_consent = true,
      editorial_consent_source = excluded.editorial_consent_source,
      updated_at = now(),
      version = app_private.participant_preferences.version + 1
    returning user_id, version
  )
  insert into app_private.audit_events (
    event_id, action, resource_type, resource_id, correlation_id, minimal_change
  )
  select target_event, 'newsletter.administratively_activated', 'profile', a.user_id, batch_id,
    jsonb_build_object(
      'source', 'organization_activation_20260928',
      'reason', 'Eenmalige activering van bestaande accounts op expliciet verzoek van de organisatie.',
      'userOptIn', false,
      'previousPreferences', c.previous_preferences,
      'activatedVersion', a.version
    )
  from activated a join candidates c on c.id = a.user_id;
  get diagnostics changed_count = row_count;

  if changed_count <> account_count - prior_active_count then
    raise exception 'NACHTPOST_ACTIVATION_COUNT_MISMATCH';
  end if;

  -- Use the real recipient selector: deduplication and delivery blocks still apply.
  audience := app_private.editorial_audience_counts(target_event, '{"roles":["subscribers"]}');

  insert into app_private.audit_events (
    event_id, action, resource_type, resource_id, correlation_id, minimal_change
  ) values (
    target_event, 'newsletter.existing_accounts_activation_completed', 'event', target_event, batch_id,
    jsonb_build_object(
      'source', 'organization_activation_20260928', 'verifiedAccounts', account_count,
      'alreadyActive', prior_active_count, 'activated', changed_count,
      'audienceAfter', audience, 'campaignsStarted', 0
    )
  );

  raise notice 'Nachtpost activation completed: verified accounts %, already active %, activated %, audience %',
    account_count, prior_active_count, changed_count, audience;
end
$$;
