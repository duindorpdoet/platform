-- Forward-only transport correction for PostgREST14 automatic40001 retries.
-- 001--004 and every historical row remain untouched. The existing checked
-- implementations retain all actor/event/capability/receipt/financial guards.
-- Only deliberate, exact business-conflict messages are non-retryablePT409.
-- A real PostgreSQL serialization_failure (or any unknown40001) is rethrown.
create function app_private.fn_is_domain_conflict(p_state text,p_message text)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(p_state='40001' and p_message=any(array[
'ALREADY_STARTED','DESTINATION_CONFLICT','IDEMPOTENCY_CONFLICT','RESERVATION_EXPIRED_RESUME','ROUTE_WINDOW_END_RESUME','VERSION_CONFLICT','ZONE_UNAVAILABLE_RESUME','GENERAL_THANKS_ALREADY_SENT','PAYMENT_ALREADY_BOUND','REFUND_ALREADY_REQUESTED','REFUND_PROVIDER_CONFLICT','ORDER_PROVIDER_IMMUTABLE','SANDBOX_RUN_CONFLICT','SANDBOX_REARM_REQUIRED','PROVIDER_CLAIM_RECONCILIATION_REQUIRED','PROVIDER_CLAIM_REQUIRED']::text[]),false);
$$;
revoke all on function app_private.fn_is_domain_conflict(text,text) from public,anon,authenticated,service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_command(text,text,jsonb,uuid) set schema app_private;
alter function app_private.frightnight_command(text,text,jsonb,uuid) rename to fn_command_transport_impl;
revoke all on function app_private.fn_command_transport_impl(text,text,jsonb,uuid) from public,anon,authenticated,service_role;
create function api.frightnight_command(p_slug text,p_command text,p_payload jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_command_transport_impl(p_slug,p_command,p_payload,p_key);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_command(text,text,jsonb,uuid) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_command(text,text,jsonb,uuid) to authenticated;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_contract_arm(text,uuid,uuid,text) set schema app_private;
alter function app_private.frightnight_contract_arm(text,uuid,uuid,text) rename to fn_contract_arm_transport_impl;
revoke all on function app_private.fn_contract_arm_transport_impl(text,uuid,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_contract_arm(p_slug text,p_actor uuid,p_run_id uuid,p_confirmation text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_contract_arm_transport_impl(p_slug,p_actor,p_run_id,p_confirmation);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_contract_arm(text,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_contract_arm(text,uuid,uuid,text) to service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_payment_claim(text,uuid,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_claim(text,uuid,uuid,text) rename to fn_payment_claim_transport_impl;
revoke all on function app_private.fn_payment_claim_transport_impl(text,uuid,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_claim(p_slug text,p_actor uuid,p_key uuid,p_configured_provider text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_payment_claim_transport_impl(p_slug,p_actor,p_key,p_configured_provider);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_payment_claim(text,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_payment_claim(text,uuid,uuid,text) to service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) rename to fn_payment_test_claim_transport_impl;
revoke all on function app_private.fn_payment_test_claim_transport_impl(text,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_test_claim(p_slug text,p_actor uuid,p_registration uuid,p_key uuid,p_configured_provider text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_payment_test_claim_transport_impl(p_slug,p_actor,p_registration,p_key,p_configured_provider);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) to service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_payment_bind(text,uuid,text,text) set schema app_private;
alter function app_private.frightnight_payment_bind(text,uuid,text,text) rename to fn_payment_bind_transport_impl;
revoke all on function app_private.fn_payment_bind_transport_impl(text,uuid,text,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_bind(p_slug text,p_order_id uuid,p_provider_ref text,p_checkout_url text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_payment_bind_transport_impl(p_slug,p_order_id,p_provider_ref,p_checkout_url);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_payment_bind(text,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_payment_bind(text,uuid,text,text) to service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) rename to fn_payment_for_refund_transport_impl;
revoke all on function app_private.fn_payment_for_refund_transport_impl(text,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_for_refund(p_slug text,p_actor uuid,p_registration uuid,p_key uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_payment_for_refund_transport_impl(p_slug,p_actor,p_registration,p_key,p_reason);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text) to service_role;

-- Preserve the reviewed implementation, argument names and exact caller grant.
alter function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) set schema app_private;
alter function app_private.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) rename to fn_payment_refund_record_transport_impl;
revoke all on function app_private.fn_payment_refund_record_transport_impl(text,uuid,uuid,text,text,uuid,text) from public,anon,authenticated,service_role;
create function api.frightnight_payment_refund_record(p_slug text,p_actor uuid,p_order_id uuid,p_provider_ref text,p_status text,p_key uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.fn_payment_refund_record_transport_impl(p_slug,p_actor,p_order_id,p_provider_ref,p_status,p_key,p_reason);
exception when serialization_failure then
 if app_private.fn_is_domain_conflict(SQLSTATE,SQLERRM) then
  raise sqlstate 'PT409' using message=SQLERRM;
 end if;
 raise;
end $$;
revoke all on function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text) to service_role;

-- Read-onlyRPCs and financial acknowledgements without deliberate40001 are
-- unchanged. Owner-only legacy fixture bridges remain owner-only.
