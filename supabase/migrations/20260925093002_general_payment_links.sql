-- Accept provider-independent HTTPS payment links while keeping URL validation
-- server-side. The public API signatures and authorization boundaries stay unchanged.

create or replace function app_private.is_safe_payment_url(_url text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    char_length(trim(_url)) between 20 and 1000
      and trim(_url) ~* '^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,63}([/?#][^[:space:]\\@]*)?$',
    false
  );
$$;

revoke all on function app_private.is_safe_payment_url(text) from public, anon, authenticated;

create or replace function app_private.payment_set_external_link_before_shared(
  _payment_request_id uuid,
  _expected_version integer,
  _external_url text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  payment app_private.payment_requests;
  registration app_private.registrations;
  normalized_url text := trim(_external_url);
begin
  if not app_private.is_safe_payment_url(normalized_url)
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select request.* into payment
  from app_private.payment_requests request
  join app_private.registrations registration_record on registration_record.id = request.registration_id
  where request.id = _payment_request_id for update of request;
  select * into registration from app_private.registrations where id = payment.registration_id;
  if payment.id is null or not (
    app_private.has_capability(registration.event_id, 'event_admin', actor)
    or app_private.has_capability(registration.event_id, 'payments_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if payment.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if payment.status not in ('awaiting_link', 'awaiting_payment') then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.payment_requests
  set external_url = normalized_url, status = 'awaiting_payment', version = version + 1
  where id = payment.id returning * into payment;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'payment.external_link_set', 'payment_request', payment.id, jsonb_build_object('provider', 'external_https', 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', payment.id, 'status', payment.status, 'version', payment.version, 'externalUrl', payment.external_url);
end;
$$;

create or replace function api.admin_payment_batch_publish(_event_slug text, _payments jsonb, _external_url text, _reason text, _idempotency_key text, _payer_payment_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid:=auth.uid(); v_event_id uuid; item record; p app_private.payment_requests;
  b app_private.payment_link_batches; existing_batch uuid; batch_count integer; total integer:=0; payer_id uuid;
  request_hash text; receipt app_private.command_receipts; result jsonb; url text:=trim(_external_url);
begin
  select e.id into v_event_id from app_private.events e where e.slug=_event_slug;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'payments_manage',actor) or app_private.has_capability(v_event_id,'event_admin',actor))
    then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _payments is null or jsonb_typeof(_payments)<>'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  if jsonb_array_length(_payments) not between 1 and 100
    or not app_private.is_safe_payment_url(url)
    or char_length(trim(coalesce(_reason,''))) not between 10 and 500
    or char_length(coalesce(_idempotency_key,'')) not between 1 and 200
    then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  if (select count(distinct (x->>'id')::uuid) from jsonb_array_elements(_payments) x) <> jsonb_array_length(_payments)
    or exists(select 1 from jsonb_array_elements(_payments) x where x->>'version' is null)
    then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  payer_id:=coalesce(_payer_payment_request_id,(_payments->0->>'id')::uuid);
  if not exists(select 1 from jsonb_array_elements(_payments) x where (x->>'id')::uuid=payer_id) then raise exception 'INVALID_PAYER' using errcode='22023'; end if;
  request_hash := encode(extensions.digest(jsonb_build_object('eventId',v_event_id,'payer',payer_id,'payments',_payments,'url',url,'reason',trim(_reason))::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||v_event_id,0));
  select * into receipt from app_private.command_receipts where actor_id=actor and command_type='payment.batchPublish' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
    return receipt.safe_result;
  end if;
  for item in select (x->>'id')::uuid id,(x->>'version')::integer version from jsonb_array_elements(_payments) x order by 1 loop
    select * into p from app_private.payment_requests where id=item.id for update;
    if p.id is null or not exists(select 1 from app_private.registrations r where r.id=p.registration_id and r.event_id=v_event_id and r.status<>'cancelled')
      then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
    if p.version<>item.version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
    if p.status not in ('awaiting_link','awaiting_payment') or p.amount_cents<=0 or exists(
      select 1 from app_private.payment_entries e where e.request_id=p.id and e.entry_type<>'reported' and e.amount_cents<>0)
      then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
    total:=total+p.amount_cents;
    if p.payment_batch_id is not null then
      if existing_batch is not null and existing_batch<>p.payment_batch_id then raise exception 'BATCH_MEMBERSHIP_MISMATCH' using errcode='23514'; end if;
      existing_batch:=p.payment_batch_id;
    end if;
  end loop;
  if existing_batch is null then
    insert into app_private.payment_link_batches(event_id,external_url,total_amount_cents,created_by,payer_payment_request_id)
    values(v_event_id,url,total,actor,payer_id) returning * into b;
    insert into app_private.payment_link_batch_members(batch_id,payment_request_id,amount_cents)
    select b.id,pay.id,pay.amount_cents from app_private.payment_requests pay
    where pay.id in (select (x->>'id')::uuid from jsonb_array_elements(_payments) x);
  else
    select * into b from app_private.payment_link_batches where id=existing_batch for update;
    select count(*) into batch_count from app_private.payment_link_batch_members where batch_id=b.id;
    if batch_count<>jsonb_array_length(_payments) or exists(
      select 1 from jsonb_array_elements(_payments) x where not exists(select 1 from app_private.payment_link_batch_members m where m.batch_id=b.id and m.payment_request_id=(x->>'id')::uuid))
      then raise exception 'BATCH_MEMBERSHIP_MISMATCH' using errcode='23514'; end if;
    if b.status<>'awaiting_payment' or app_private.payment_batch_payload(b.id)->>'status'='needs_review'
      then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
    if b.external_url=url and b.payer_payment_request_id=payer_id then
      result:=app_private.payment_batch_payload(b.id);
      insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
      values(actor,'payment.batchPublish',_idempotency_key,request_hash,result,now()+interval '1 year');
      return result;
    end if;
    update app_private.payment_link_batches set external_url=url,payer_payment_request_id=payer_id,version=version+1,updated_at=now() where id=b.id returning * into b;
  end if;
  update app_private.payment_requests set payment_batch_id=b.id,external_url=url,status='awaiting_payment',version=version+1
  where id in (select payment_request_id from app_private.payment_link_batch_members where batch_id=b.id);
  perform app_private.enqueue_payment_batch_email(b.id,'payment_link_ready');
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(v_event_id,actor,'payment.batch_published','payment_batch',b.id,jsonb_build_object('amountCents',total,'count',jsonb_array_length(_payments),'reason',trim(_reason)));
  result:=app_private.payment_batch_payload(b.id);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
  values(actor,'payment.batchPublish',_idempotency_key,request_hash,result,now()+interval '1 year');
  return result;
end $$;

create or replace function app_private.admin_child_payment_publish_before_registration_scope(_event_slug text,_children jsonb,_anchor_child_id uuid,_external_url text,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; rc app_private.registration_children; p app_private.payment_requests; item record;
 b app_private.child_payment_batches; existing uuid; total integer:=0; receipt app_private.command_receipts; hash text; result jsonb; url text:=trim(_external_url);
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or not(app_private.has_capability(eid,'payments_manage',actor) or app_private.has_capability(eid,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _children is null or jsonb_typeof(_children)<>'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if jsonb_array_length(_children) not between 1 and 100 or not app_private.is_safe_payment_url(url)
 or char_length(trim(coalesce(_reason,''))) not between 10 and 500 or char_length(coalesce(_idempotency_key,'')) not between 1 and 200
 or (select count(distinct (x->>'id')::uuid) from jsonb_array_elements(_children) x)<>jsonb_array_length(_children)
 or exists(select 1 from jsonb_array_elements(_children) x where x->>'version' is null)
 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if not exists(select 1 from jsonb_array_elements(_children) x where (x->>'id')::uuid=_anchor_child_id) then raise exception 'INVALID_ANCHOR_CHILD' using errcode='22023'; end if;
 hash:=encode(extensions.digest(jsonb_build_object('event',eid,'children',_children,'anchor',_anchor_child_id,'url',url,'reason',_reason)::text,'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||eid,0));
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='payment.childPublish' and idempotency_key=_idempotency_key;
 if receipt.id is not null then
   if receipt.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
   return receipt.safe_result;
 end if;
 -- Same event lock as existing whole-registration payments; rows locked consistently.
 perform 1 from app_private.payment_requests pp where pp.registration_id in(select rcc.registration_id from app_private.registration_children rcc where rcc.event_id=eid and rcc.child_id in(select (x->>'id')::uuid from jsonb_array_elements(_children) x)) order by pp.id for update;
 for item in select (x->>'id')::uuid id,(x->>'version')::integer version from jsonb_array_elements(_children) x order by 1 loop
   select * into rc from app_private.registration_children where event_id=eid and child_id=item.id for update;
   if rc.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if rc.payment_version is distinct from item.version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
   select * into p from app_private.payment_requests where registration_id=rc.registration_id order by created_at desc limit 1;
   if p.id is null or rc.participation_status<>'active' or rc.unit_price_cents<=0 or exists(select 1 from app_private.registrations where id=rc.registration_id and status='cancelled') then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
   if p.payment_batch_id is not null or p.external_url is not null then raise exception 'LEGACY_PAYMENT_LINK_ACTIVE' using errcode='23514'; end if;
   if not p.child_payment_mode and (p.status not in('awaiting_link','awaiting_payment') or exists(select 1 from app_private.payment_entries where request_id=p.id and entry_type<>'reported' and amount_cents<>0)) then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
   if p.child_payment_mode and (select coalesce(sum(e.amount_cents),0) from app_private.payment_entries e where e.request_id=p.id and e.entry_type<>'reported')<>(select coalesce(sum(m.amount_cents),0) from app_private.child_payment_members m join app_private.child_payment_batches cb on cb.id=m.batch_id where m.payment_request_id=p.id and cb.status='confirmed') then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
   if rc.child_payment_batch_id is not null then
     if existing is not null and existing<>rc.child_payment_batch_id then raise exception 'BATCH_MEMBERSHIP_MISMATCH' using errcode='23514'; end if;
     existing:=rc.child_payment_batch_id;
   end if;
   total:=total+rc.unit_price_cents;
 end loop;
 if existing is null then
   insert into app_private.child_payment_batches(event_id,anchor_child_id,external_url,total_amount_cents,created_by) values(eid,_anchor_child_id,url,total,actor) returning * into b;
   insert into app_private.child_payment_members(batch_id,registration_child_id,payment_request_id,amount_cents)
   select b.id,rcc.id,pp.id,rcc.unit_price_cents from app_private.registration_children rcc
   join lateral(select pr.id from app_private.payment_requests pr where pr.registration_id=rcc.registration_id order by pr.created_at desc limit 1) pp on true
   where rcc.event_id=eid and rcc.child_id in(select (x->>'id')::uuid from jsonb_array_elements(_children) x);
 else
   select * into b from app_private.child_payment_batches where id=existing for update;
   if b.status<>'awaiting_payment' or app_private.child_payment_batch_payload(b.id)->>'status'='needs_review' then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
   if (select count(*) from app_private.child_payment_members where batch_id=b.id)<>jsonb_array_length(_children)
     or exists(select 1 from jsonb_array_elements(_children) x where not exists(select 1 from app_private.child_payment_members m join app_private.registration_children rcc on rcc.id=m.registration_child_id where m.batch_id=b.id and rcc.child_id=(x->>'id')::uuid)) then raise exception 'BATCH_MEMBERSHIP_MISMATCH' using errcode='23514'; end if;
   if b.external_url=url and b.anchor_child_id=_anchor_child_id then
     result:=app_private.child_payment_batch_payload(b.id);
     insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'payment.childPublish',_idempotency_key,hash,result,now()+interval '1 year'); return result;
   end if;
   update app_private.child_payment_batches set external_url=url,anchor_child_id=_anchor_child_id,version=version+1 where id=b.id returning * into b;
 end if;
 update app_private.payment_requests set child_payment_mode=true,status=case when status='awaiting_link' then 'awaiting_payment'::app_private.payment_status else status end,version=version+1 where id in(select payment_request_id from app_private.child_payment_members where batch_id=b.id);
 update app_private.registration_children set child_payment_batch_id=b.id,payment_version=payment_version+1 where id in(select registration_child_id from app_private.child_payment_members where batch_id=b.id);
 perform app_private.enqueue_child_payment_email(b.id,'payment_link_ready');
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(eid,actor,'payment.child_published','child_payment_batch',b.id,jsonb_build_object('count',jsonb_array_length(_children),'amountCents',total,'reason',_reason));
 result:=app_private.child_payment_batch_payload(b.id);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'payment.childPublish',_idempotency_key,hash,result,now()+interval '1 year'); return result;
end $$;

revoke all on function app_private.admin_child_payment_publish_before_registration_scope(text, jsonb, uuid, text, text, text) from public, anon, authenticated;
revoke all on function app_private.payment_set_external_link_before_shared(uuid, integer, text, text) from public, anon, authenticated;
revoke all on function api.admin_payment_batch_publish(text, jsonb, text, text, text, uuid) from public, anon;
grant execute on function api.admin_payment_batch_publish(text, jsonb, text, text, text, uuid) to authenticated;
