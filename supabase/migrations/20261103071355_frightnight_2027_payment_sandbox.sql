-- Forward-only: the two deployed FrightNight migrations remain byte-identical.
-- Existing provider references/history are preserved; only new metadata is added.
alter table app_private.fn_events add column payment_policy text not null default 'configured' check(payment_policy in('configured','contract_sandbox'));
alter table app_private.fn_events add column contract_run_id uuid;
alter table app_private.fn_events add constraint fn_payment_policy_run check((payment_policy='configured' and contract_run_id is null) or (payment_policy='contract_sandbox' and contract_run_id is not null));
alter table app_private.fn_orders add column provider_claimed_at timestamptz;
-- Bound receipts already identify their provider. An old ambiguous/unbound
-- attempt is deliberately not reinterpreted under a different server setting.
update app_private.fn_orders set provider_claimed_at=created_at where provider_ref is not null and ((provider='contract' and provider_ref~'^ct_[a-f0-9-]{36}$') or (provider='mollie' and provider_ref~'^tr_[A-Za-z0-9]+$'));
alter table app_private.fn_orders add constraint fn_order_provider_reference check(provider_ref is null or (provider='contract' and provider_ref~'^ct_[a-f0-9-]{36}$') or (provider='mollie' and provider_ref~'^tr_[A-Za-z0-9]+$'));

create function app_private.fn_immutable_order_provider() returns trigger language plpgsql set search_path='' as $$
begin
 if old.provider_claimed_at is not null and (new.provider is distinct from old.provider or new.provider_claimed_at is distinct from old.provider_claimed_at) then raise exception 'ORDER_PROVIDER_IMMUTABLE' using errcode='40001'; end if;
 return new;
end $$;
revoke all on function app_private.fn_immutable_order_provider() from public,anon,authenticated,service_role;
create trigger fn_orders_provider_immutable before update on app_private.fn_orders for each row execute function app_private.fn_immutable_order_provider();

create or replace function app_private.fn_order_json(p_id uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('order_id',id,'event_id',event_id,'registration_id',registration_id,'amount_cents',amount_cents,'currency',currency,'status',status,'provider_ref',provider_ref,'checkout_url',checkout_url,'provider',provider,'provider_claimed',provider_claimed_at is not null) from app_private.fn_orders where id=p_id
$$;

create function app_private.fn_payment_sandbox_json(p_event uuid,p_actor uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare f app_private.fn_events; slug text; registrations bigint; orders bigint; mollie bigint; armed boolean; why text;
begin
 select * into f from app_private.fn_events where event_id=p_event;
 select e.slug into slug from app_private.events e where e.id=p_event;
 select count(*) into registrations from app_private.fn_registrations where event_id=p_event and run_id=f.run_id;
 select count(*) into orders from app_private.fn_orders o join app_private.fn_registrations r on r.event_id=o.event_id and r.id=o.registration_id where o.event_id=p_event and r.run_id=f.run_id;
 select count(*) into mollie from app_private.fn_orders where event_id=p_event and provider='mollie';
 armed:=f.payment_policy='contract_sandbox' and f.contract_run_id=f.run_id;
 why:=case when not app_private.fn_context_allowed(p_event,p_actor) or not app_private.fn_can(p_event,'test_manage',p_actor) then 'TEST_ADMIN_REQUIRED' when slug='frightnight-2027-test' then 'CANONICAL_SANDBOX_FORBIDDEN' when f.environment<>'staging' or not f.is_test or slug not like 'frightnight-2027-test-%' then 'TEST_SCOPE_REQUIRED' when f.closed then 'EDITION_CLOSED' when armed then 'ALREADY_ARMED' when mollie>0 then 'MOLLIE_HISTORY_FORBIDDEN' when f.seed_version<>0 or registrations>0 or orders>0 then 'FRESH_RUN_REQUIRED' else null end;
 return jsonb_build_object('policy',f.payment_policy,'runId',f.run_id,'sandboxRunId',f.contract_run_id,'armed',armed,'canArm',why is null,'reason',why,'registrations',registrations,'orders',orders,'mollieOrders',mollie,'canonical',slug='frightnight-2027-test');
end $$;
revoke all on function app_private.fn_payment_sandbox_json(uuid,uuid) from public,anon,authenticated,service_role;

create or replace function api.frightnight_snapshot(p_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; f app_private.fn_events; result jsonb;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events fe on fe.event_id=e.id where e.slug=p_slug and fe.environment='staging' and fe.is_test;
 if not app_private.fn_context_allowed(eid,actor) then raise exception 'EDITION_ACCESS_REQUIRED' using errcode='42501'; end if;
 select * into f from app_private.fn_events where event_id=eid;
 result:=app_private.fn_snapshot_impl(p_slug);
 result:=jsonb_set(result,'{event}',(result->'event')||jsonb_build_object('paymentPolicy',f.payment_policy,'sandboxRunId',f.contract_run_id,'contractSandboxArmed',f.payment_policy='contract_sandbox' and f.contract_run_id=f.run_id));
 if app_private.fn_can(eid,'test_manage',actor) then result:=result||jsonb_build_object('paymentSandbox',app_private.fn_payment_sandbox_json(eid,actor)); end if;
 return result;
end $$;
revoke all on function api.frightnight_snapshot(text) from public,anon,service_role;
grant execute on function api.frightnight_snapshot(text) to authenticated;

create function api.frightnight_contract_arm(p_slug text,p_actor uuid,p_run_id uuid,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; f app_private.fn_events; eligibility jsonb;
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 select e.id into eid from app_private.events e join app_private.fn_events fe on fe.event_id=e.id where e.slug=p_slug and fe.environment='staging' and fe.is_test for update of fe;
 select * into f from app_private.fn_events where event_id=eid;
 if not app_private.fn_context_allowed(eid,p_actor) or not app_private.fn_can(eid,'test_manage',p_actor) then raise exception 'TEST_ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_run_id is distinct from f.run_id then raise exception 'SANDBOX_RUN_CONFLICT' using errcode='40001'; end if;
 if p_confirmation is distinct from 'nocteiuvohesvqbowchw:staging:duindorphalloweenstg:'||p_slug||':'||p_run_id::text then raise exception 'SANDBOX_CONFIRMATION_REQUIRED' using errcode='22023'; end if;
 eligibility:=app_private.fn_payment_sandbox_json(eid,p_actor);
 if eligibility->>'reason'='ALREADY_ARMED' then return jsonb_build_object('eventId',eid,'slug',p_slug,'runId',f.run_id,'paymentPolicy','contract_sandbox','sandboxRunId',f.run_id,'provider','contract','armed',true); end if;
 if not(eligibility->>'canArm')::boolean then raise exception '%',eligibility->>'reason' using errcode='42501'; end if;
 update app_private.fn_events set payment_policy='contract_sandbox',contract_run_id=run_id,version=version+1 where event_id=eid;
 insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,p_actor,'payment.sandbox_armed',jsonb_build_object('runId',f.run_id,'provider','contract','delegation','service-role:verified-actor','canonical',false));
 return jsonb_build_object('eventId',eid,'slug',p_slug,'runId',f.run_id,'paymentPolicy','contract_sandbox','sandboxRunId',f.run_id,'provider','contract','armed',true);
end $$;
revoke all on function api.frightnight_contract_arm(text,uuid,uuid,text) from public,anon,authenticated;
grant execute on function api.frightnight_contract_arm(text,uuid,uuid,text) to service_role;

create function app_private.fn_payment_provider(p_event uuid,p_configured_provider text) returns text language plpgsql stable set search_path='' as $$
declare f app_private.fn_events;
begin
 select * into f from app_private.fn_events where event_id=p_event;
 if f.event_id is null or f.environment<>'staging' or not f.is_test then raise exception 'TEST_SCOPE_REQUIRED' using errcode='42501'; end if;
 if f.payment_policy='contract_sandbox' then
  if f.contract_run_id is distinct from f.run_id then raise exception 'SANDBOX_REARM_REQUIRED' using errcode='40001'; end if;
  return 'contract';
 end if;
 if p_configured_provider is null or p_configured_provider not in('contract','mollie') then raise exception 'CONFIGURED_PROVIDER_REQUIRED' using errcode='22023'; end if;
 return p_configured_provider;
end $$;
revoke all on function app_private.fn_payment_provider(uuid,text) from public,anon,authenticated,service_role;

create function api.frightnight_payment_claim(p_slug text,p_actor uuid,p_key uuid,p_configured_provider text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; selected_provider text; existing uuid[]; result jsonb; oid uuid; o app_private.fn_orders;
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test for update of f;
 selected_provider:=app_private.fn_payment_provider(eid,p_configured_provider);
 select coalesce(array_agg(id),'{}'::uuid[]) into existing from app_private.fn_orders where event_id=eid and registration_id=app_private.fn_registration(eid,p_actor);
 result:=app_private.fn_payment_create_impl(p_slug,p_actor,p_key);oid:=(result->>'order_id')::uuid;
 select * into o from app_private.fn_orders where event_id=eid and id=oid for update;
 if o.provider_claimed_at is null then
  if oid=any(existing) then raise exception 'PROVIDER_CLAIM_RECONCILIATION_REQUIRED' using errcode='40001'; end if;
  update app_private.fn_orders set provider=selected_provider,provider_claimed_at=clock_timestamp() where id=oid;
 end if;
 return app_private.fn_order_json(oid);
end $$;
revoke all on function api.frightnight_payment_claim(text,uuid,uuid,text) from public,anon,authenticated;
grant execute on function api.frightnight_payment_claim(text,uuid,uuid,text) to service_role;

-- Owner-only SQL fixture bridges remain contract-only. Neither browser nor
-- service role can invoke them; the application must supply its trusted provider
-- through payment_claim before an external side effect.
create or replace function api.frightnight_payment_create(p_slug text,p_actor uuid,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin return api.frightnight_payment_claim(p_slug,p_actor,p_key,'contract');end $$;
revoke all on function api.frightnight_payment_create(text,uuid,uuid) from public,anon,authenticated,service_role;

create function api.frightnight_payment_test_claim(p_slug text,p_actor uuid,p_registration uuid,p_key uuid,p_configured_provider text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; existing uuid[]; oid uuid; result jsonb; o app_private.fn_orders;
begin
 perform app_private.fn_require_context(p_slug,p_actor);
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test for update of f;
 if app_private.fn_payment_provider(eid,p_configured_provider)<>'contract' then raise exception 'CONTRACT_ONLY' using errcode='42501'; end if;
 select coalesce(array_agg(id),'{}'::uuid[]) into existing from app_private.fn_orders where event_id=eid and registration_id=p_registration;
 result:=app_private.fn_payment_test_order_impl(p_slug,p_actor,p_registration,p_key);oid:=(result->>'order_id')::uuid;
 select * into o from app_private.fn_orders where event_id=eid and id=oid for update;
 if o.provider<>'contract' then raise exception 'CONTRACT_ORDER_REQUIRED' using errcode='42501'; end if;
 if o.provider_claimed_at is null then
  if oid=any(existing) then raise exception 'PROVIDER_CLAIM_RECONCILIATION_REQUIRED' using errcode='40001'; end if;
  update app_private.fn_orders set provider_claimed_at=clock_timestamp() where id=oid;
 end if;
 return app_private.fn_order_json(oid);
end $$;
revoke all on function api.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function api.frightnight_payment_test_claim(text,uuid,uuid,uuid,text) to service_role;
create or replace function api.frightnight_payment_test_order(p_slug text,p_actor uuid,p_registration uuid,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin return api.frightnight_payment_test_claim(p_slug,p_actor,p_registration,p_key,'contract');end $$;
revoke all on function api.frightnight_payment_test_order(text,uuid,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function api.frightnight_payment_bind(p_slug text,p_order_id uuid,p_provider_ref text,p_checkout_url text) returns jsonb language plpgsql security definer set search_path='' as $$
declare o app_private.fn_orders; eid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test for update of f;
 select * into o from app_private.fn_orders where event_id=eid and id=p_order_id for update;
 if o.id is null or o.provider_claimed_at is null then raise exception 'PROVIDER_CLAIM_REQUIRED' using errcode='40001'; end if;
 if p_provider_ref is null or (o.provider='contract' and p_provider_ref!~'^ct_[a-f0-9-]{36}$') or (o.provider='mollie' and p_provider_ref!~'^tr_[A-Za-z0-9]+$') then raise exception 'INVALID_PAYMENT_BINDING' using errcode='22023'; end if;
 if o.provider_ref is not null and o.provider_ref<>p_provider_ref then raise exception 'PAYMENT_ALREADY_BOUND' using errcode='40001'; end if;
 if p_checkout_url is not null and not((o.provider='mollie' and p_checkout_url~'^https://([a-zA-Z0-9-]+\.)*mollie\.com/') or (o.provider='contract' and p_checkout_url like 'https://staging-halloween.duindorpdoet.nl/%')) then raise exception 'INVALID_CHECKOUT_URL' using errcode='22023'; end if;
 update app_private.fn_orders set provider_ref=p_provider_ref,checkout_url=coalesce(p_checkout_url,checkout_url) where id=o.id;
 return app_private.fn_order_json(o.id);
end $$;
revoke all on function api.frightnight_payment_bind(text,uuid,text,text) from public,anon,authenticated;
grant execute on function api.frightnight_payment_bind(text,uuid,text,text) to service_role;
