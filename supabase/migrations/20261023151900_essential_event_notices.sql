-- Necessary event notices have a transactional delivery policy. No newsletter
-- preferences or consent histories are changed, no message is sent by this
-- migration, and recipients are resolved afresh on each explicit publication.
set lock_timeout='5s';

create or replace function api.admin_publish_participant_update(
  _event_slug text,
  _audience_role text,
  _title text,
  _body text,
  _priority text default 'normal',
  _send_email boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  update_record app_private.participant_updates;
  recipient record;
  v_count integer := 0;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if actor is null or v_event_id is null or not (
    app_private.has_capability(v_event_id, 'live_support', actor) or app_private.has_capability(v_event_id, 'content_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _audience_role not in ('all', 'walker', 'viewer', 'homeowner')
     or _priority not in ('normal', 'important', 'urgent')
     or char_length(trim(coalesce(_title, ''))) not between 3 and 120
     or char_length(trim(coalesce(_body, ''))) not between 3 and 1200 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  insert into app_private.participant_updates(event_id, audience_role, title, body, priority, created_by)
  values (v_event_id, _audience_role, trim(_title), trim(_body), _priority, actor)
  returning * into update_record;
  if coalesce(_send_email,false) or _priority in ('important','urgent') then
    for recipient in
      select distinct on (recipient_user_id) recipient_user_id, recipient_email, recipient_role from (
        select member.user_id as recipient_user_id, lower(users.email) as recipient_email, 'walker'::text as recipient_role
        from app_private.household_members member
        join auth.users users on users.id = member.user_id
        join app_private.registrations registration on registration.household_id = member.household_id
        where registration.event_id = v_event_id and registration.status <> 'cancelled' and member.revoked_at is null
          and _audience_role in ('all', 'walker')
        union all
        select access.user_id, lower(users.email), 'viewer'::text
        from app_private.group_viewer_access access
        join auth.users users on users.id = access.user_id
        where access.event_id = v_event_id and access.revoked_at is null
          and (access.expires_at is null or access.expires_at > now()) and _audience_role in ('all', 'viewer')
        union all
        select owner.user_id, lower(users.email), 'homeowner'::text
        from app_private.portal_owners owner
        join app_private.portals portal on portal.id = owner.portal_id
        join auth.users users on users.id = owner.user_id
        where portal.event_id = v_event_id and owner.revoked_at is null and _audience_role in ('all', 'homeowner')
        union all
        select leader.user_id, lower(users.email), 'walker'::text
        from app_private.group_leaders leader
        join app_private.walking_groups walking_group on walking_group.id = leader.group_id
        join auth.users users on users.id = leader.user_id
        where walking_group.event_id = v_event_id and leader.active_from <= now()
          and (leader.active_until is null or leader.active_until > now())
          and _audience_role in ('all','walker') and _priority in ('important','urgent')
        union all
        select application.applicant_user_id, lower(users.email), 'applicant'::text
        from app_private.portal_applications application
        join auth.users users on users.id = application.applicant_user_id
        where application.event_id = v_event_id
          and application.review_status not in ('withdrawn','rejected')
          and _audience_role in ('all','homeowner')
          and _priority in ('important','urgent')
      ) recipients
      where nullif(trim(recipient_email),'') is not null
      and (_priority in ('important','urgent') or coalesce((
        select preference.email_updates
        from app_private.participant_preferences preference
        where preference.event_id = v_event_id and preference.user_id = recipients.recipient_user_id
      ), true))
      order by recipient_user_id,
        case recipient_role when 'walker' then 1 when 'viewer' then 2 else 3 end
    loop
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'participant-update:' || update_record.id::text || ':' || recipient.recipient_user_id::text,
        'participant_update',
        'participant_update:' || update_record.id::text || ':' || recipient.recipient_user_id::text,
        recipient.recipient_email,
        jsonb_build_object(
          'mandatoryEventNotice', _priority in ('important','urgent'),
          'priority', _priority,
          'title', update_record.title,
          'message', update_record.body,
          'actionPath', case when recipient.recipient_role='applicant' then '/omgeving' else '/omgeving/' || case recipient.recipient_role when 'walker' then 'meeloper' when 'viewer' then 'meekijker' else 'huiseigenaar' end || '/updates' end
        )
      ) on conflict (dedupe_key) do nothing;
      v_count := v_count + 1;
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'participant.update_published', 'participant_update', update_record.id,
    jsonb_build_object('audienceRole', _audience_role, 'emailCount', v_count,
      'priority',_priority,'mandatoryEventNotice',_priority in ('important','urgent'),
      'audiencePolicy','current_event_participants_at_publication'));
  return jsonb_build_object('id', update_record.id, 'emailCount', v_count,
    'mandatoryEventNotice',_priority in ('important','urgent'));
end;
$$;
