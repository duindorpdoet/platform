-- Household labels are operational identifiers, not visitor-authored names.
-- Remove previously collected labels and legacy draft fields so new and
-- existing registrations use the same privacy-preserving convention.
update app_private.households
set label = 'Gezelschap ' || upper(substr(replace(id::text, '-', ''), 1, 6)),
    version = version + 1
where label is distinct from 'Gezelschap ' || upper(substr(replace(id::text, '-', ''), 1, 6));

update app_private.registration_drafts
set payload = jsonb_set(
      payload - 'togetherCode',
      '{adult}',
      coalesce(payload -> 'adult', '{}'::jsonb) - 'householdLabel',
      true
    ) || jsonb_build_object(
      'togetherPreference',
      left(trim(coalesce(payload ->> 'togetherPreference', payload ->> 'togetherCode', '')), 160)
    ),
    version = version + 1
where jsonb_typeof(payload) = 'object';

create or replace function api.registration_save_draft(
  _event_slug text,
  _payload jsonb,
  _expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  adult_name text := nullif(trim(_payload #>> '{adult,name}'), '');
  together_preference text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or jsonb_typeof(_payload -> 'adult') <> 'object' or adult_name is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  together_preference := left(trim(coalesce(_payload ->> 'togetherPreference', _payload ->> 'togetherCode', '')), 160);
  _payload := jsonb_set(
      _payload - 'togetherCode',
      '{adult}',
      (_payload -> 'adult') - 'householdLabel',
      true
    ) || jsonb_build_object('togetherPreference', together_preference);

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();
    insert into app_private.households(id, label, primary_contact_user_id, phone)
    values (
      v_household_id,
      'Gezelschap ' || upper(substr(replace(v_household_id::text, '-', ''), 1, 6)),
      actor,
      nullif(trim(_payload #>> '{adult,phone}'), '')
    );
    insert into app_private.household_members(household_id, user_id, relation_role) values (v_household_id, actor, 'owner');
  else
    update app_private.households
    set phone = nullif(trim(_payload #>> '{adult,phone}'), ''),
        version = version + 1
    where id = v_household_id;
  end if;

  update app_private.profiles set display_name = adult_name, version = version + 1 where user_id = actor;

  insert into app_private.registration_drafts(event_id, household_id, payload)
  values (v_event_id, v_household_id, _payload)
  on conflict (event_id, household_id) do update
    set payload = excluded.payload,
        version = app_private.registration_drafts.version + 1
    where _expected_version is null or app_private.registration_drafts.version = _expected_version
  returning * into draft_record;

  if draft_record.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  return jsonb_build_object('id', draft_record.id, 'version', draft_record.version, 'savedAt', draft_record.updated_at);
end;
$$;
