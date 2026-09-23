-- Bind the private house draft to the confirmed account email, never a browser-supplied identity.
create or replace function api.portal_application_save(
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
  verified_email text;
  application app_private.portal_applications;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select email into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  _payload := _payload || jsonb_build_object('email', verified_email);
  select * into application from app_private.portal_applications
  where app_private.portal_applications.event_id = v_event_id and applicant_user_id = actor and review_status in ('draft', 'changes_requested')
  order by created_at desc limit 1 for update;
  if application.id is null then
    insert into app_private.portal_applications(event_id, applicant_user_id, private_draft_data)
    values (v_event_id, actor, _payload) returning * into application;
  else
    if _expected_version is not null and application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.portal_applications set private_draft_data = _payload, version = version + 1
    where id = application.id returning * into application;
  end if;
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'savedAt', application.updated_at);
end;
$$;

