-- A complete, organizer-only registration roster for the backoffice. The old
-- registrations tab only exposed exceptional change and together requests,
-- which made normal submitted registrations invisible to organizers.

create or replace function api.admin_registrations_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record
  from app_private.events
  where slug = _event_slug;

  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'submittedAt', registration.submitted_at,
        'updatedAt', registration.updated_at,
        'parentName', registration.parent_name,
        'parentEmail', registration.parent_email,
        'phone', registration.phone,
        'groupId', registration.group_id,
        'groupCode', registration.group_code,
        'groupName', coalesce(
          registration.group_name,
          case when registration.group_code is not null
            then 'Groep ' || registration.group_code
            else 'Groep van ' || registration.parent_name
          end
        ),
        'togetherCode', registration.together_code,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'childCount', registration.child_count,
        'children', registration.children,
        'priceCents', registration.price_snapshot_cents
      )
      order by registration.submitted_at desc nulls last, registration.created_at desc, registration.id
    )
    from (
      select
        submitted.*,
        coalesce((
          select count(*)::integer
          from app_private.registration_children registration_child
          where registration_child.registration_id = submitted.id
            and registration_child.participation_status = 'active'
        ), 0) as child_count,
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', registration_child.id,
            'name', child.first_name,
            'age', child.age_at_event,
            'accessibilityNote', child.accessibility_note,
            'status', registration_child.participation_status
          ) order by child.first_name, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child on child.id = registration_child.child_id
          where registration_child.registration_id = submitted.id
        ), '[]'::jsonb) as children
      from (
        select
          registration.id,
          registration.reference,
          registration.status,
          registration.submitted_at,
          registration.created_at,
          registration.updated_at,
          registration.together_code,
          registration.preferred_start_at,
          registration.desired_end_at,
          registration.price_snapshot_cents,
          coalesce(
            nullif(trim(draft.payload #>> '{adult,name}'), ''),
            nullif(trim(profile.display_name), ''),
            household.label,
            'Ouder'
          ) as parent_name,
          lower(users.email) as parent_email,
          household.phone,
          assigned_group.id as group_id,
          assigned_group.system_code as group_code,
          assigned_group.display_name as group_name
        from app_private.registrations registration
        join app_private.households household on household.id = registration.household_id
        join auth.users users on users.id = household.primary_contact_user_id
        left join app_private.profiles profile on profile.user_id = household.primary_contact_user_id
        left join app_private.registration_drafts draft
          on draft.event_id = registration.event_id and draft.household_id = registration.household_id
        left join lateral (
          select walking_group.id, walking_group.system_code, walking_group.display_name
          from app_private.group_registrations assignment
          join app_private.walking_groups walking_group on walking_group.id = assignment.group_id
          where assignment.registration_id = registration.id and assignment.superseded_at is null
          order by assignment.assigned_at desc, assignment.id desc
          limit 1
        ) assigned_group on true
        where registration.event_id = event_record.id
          and registration.status <> 'draft'
      ) submitted
    ) registration
  ), '[]'::jsonb);
end;
$$;

revoke all on function api.admin_registrations_snapshot(text) from public, anon;
grant execute on function api.admin_registrations_snapshot(text) to authenticated;

comment on function api.admin_registrations_snapshot(text)
  is 'Returns submitted registrations and private contact details only to event or registration administrators.';

select pg_notify('pgrst', 'reload schema');
