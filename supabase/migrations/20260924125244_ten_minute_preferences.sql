-- Preference choices and server-side validation share these increments.
-- Existing preferences and confirmed schedules are deliberately preserved.
alter table app_private.event_route_settings
  alter column preferred_start_step_minutes set default 10,
  alter column desired_end_step_minutes set default 10;

update app_private.event_route_settings
set preferred_start_step_minutes = 10,
    desired_end_step_minutes = 10,
    version = version + 1
where preferred_start_step_minutes <> 10 or desired_end_step_minutes <> 10;
