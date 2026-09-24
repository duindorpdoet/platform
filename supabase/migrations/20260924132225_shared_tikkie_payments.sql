-- One external Tikkie payment, allocated to the existing registration ledgers.
create table app_private.payment_link_batches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id),
  external_url text not null,
  payer_payment_request_id uuid not null references app_private.payment_requests(id),
  total_amount_cents integer not null check (total_amount_cents > 0),
  status text not null default 'awaiting_payment' check (status in ('awaiting_payment','reported','confirmed','cancelled')),
  version integer not null default 1,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index payment_link_batches_event_idx on app_private.payment_link_batches(event_id);
create index payment_link_batches_payer_idx on app_private.payment_link_batches(payer_payment_request_id);
create index payment_link_batches_creator_idx on app_private.payment_link_batches(created_by);
alter table app_private.payment_requests add column payment_batch_id uuid references app_private.payment_link_batches(id);
create index payment_requests_batch_idx on app_private.payment_requests(payment_batch_id) where payment_batch_id is not null;
create table app_private.payment_link_batch_members (
  batch_id uuid not null references app_private.payment_link_batches(id),
  payment_request_id uuid not null references app_private.payment_requests(id),
  amount_cents integer not null check (amount_cents > 0),
  primary key (batch_id, payment_request_id)
);
create index payment_link_batch_members_request_idx on app_private.payment_link_batch_members(payment_request_id);
alter table app_private.payment_link_batches enable row level security;
alter table app_private.payment_link_batch_members enable row level security;
revoke all on app_private.payment_link_batches, app_private.payment_link_batch_members from public, anon, authenticated;

create function app_private.payment_parent_name(_registration_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(trim(d.payload #>> '{adult,name}'), ''), nullif(trim(p.display_name), ''), h.label, 'Ouder')
  from app_private.registrations r join app_private.households h on h.id = r.household_id
  left join app_private.profiles p on p.user_id = h.primary_contact_user_id
  left join app_private.registration_drafts d on d.household_id = h.id and d.event_id = r.event_id
  where r.id = _registration_id
$$;

create function app_private.payment_batch_can_pay(_batch_id uuid, _actor uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select app_private.is_household_member(r.household_id,_actor)
    from app_private.payment_link_batches b join app_private.payment_requests p on p.id=b.payer_payment_request_id
    join app_private.registrations r on r.id=p.registration_id where b.id=_batch_id),false)
$$;

create function app_private.payment_batch_payload(_batch_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b app_private.payment_link_batches; v_status text;
begin
  select * into b from app_private.payment_link_batches where id = _batch_id;
  if b.id is null then return null; end if;
  v_status := b.status;
  if b.status in ('awaiting_payment','reported') and exists (
    select 1 from app_private.payment_link_batch_members m
    join app_private.payment_requests p on p.id = m.payment_request_id
    join app_private.registrations r on r.id = p.registration_id
    where m.batch_id = b.id and (p.amount_cents <> m.amount_cents or r.status = 'cancelled'
      or p.payment_batch_id is distinct from b.id or p.status not in ('awaiting_payment','reported')
      or exists (select 1 from app_private.payment_entries e where e.request_id = p.id and e.entry_type <> 'reported' and e.amount_cents <> 0))
  ) then v_status := 'needs_review'; end if;
  return jsonb_build_object('id', b.id, 'version', b.version, 'status', v_status,
    'totalAmountCents', b.total_amount_cents,
    'payerPaymentRequestId',b.payer_payment_request_id,
    'payerName',app_private.payment_parent_name((select registration_id from app_private.payment_requests where id=b.payer_payment_request_id)),
    'canPay',app_private.payment_batch_can_pay(b.id),
    'externalUrl', case when v_status='awaiting_payment' and (app_private.payment_batch_can_pay(b.id) or app_private.has_capability(b.event_id,'payments_manage') or app_private.has_capability(b.event_id,'event_admin')) then b.external_url end,
    'participants', (select jsonb_agg(app_private.payment_parent_name(p.registration_id) order by p.id)
      from app_private.payment_link_batch_members m join app_private.payment_requests p on p.id=m.payment_request_id where m.batch_id=b.id));
end $$;

create function app_private.enqueue_payment_batch_email(_batch_id uuid, _type text) returns void
language plpgsql security definer set search_path = '' as $$
declare b app_private.payment_link_batches; recipient record; payload jsonb;
begin
  select * into b from app_private.payment_link_batches where id=_batch_id;
  payload := app_private.payment_batch_payload(b.id);
  for recipient in
    select distinct u.id, lower(u.email) email from app_private.payment_link_batch_members bm
    join app_private.payment_requests p on p.id=bm.payment_request_id
    join app_private.registrations r on r.id=p.registration_id
    join app_private.household_members hm on hm.household_id=r.household_id and hm.revoked_at is null
    join auth.users u on u.id=hm.user_id and u.email is not null
    where bm.batch_id=b.id and (_type<>'payment_link_ready' or p.id=b.payer_payment_request_id)
  loop
    insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
    values ('payment-batch:'||b.id||':'||_type||':'||b.version||':'||recipient.id,
      _type,recipient.id::text,recipient.email,jsonb_build_object(
        'batchId',b.id,'batchVersion',b.version,'payerName',payload->>'payerName',
        'amountCents',b.total_amount_cents,'externalUrl',case when _type='payment_link_ready' then b.external_url end,
        'paymentParticipants',payload->'participants','actionPath','/omgeving/meeloper/nu'))
    on conflict (dedupe_key) do nothing;
  end loop;
end $$;

-- Batched notifications are queued once per adult, after every allocation succeeds.
create or replace function app_private.enqueue_payment_state_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  registration app_private.registrations;
  recipient record;
  v_type text;
  v_revision text;
begin
  if new.registration_id is null or new.payment_batch_id is not null then return new; end if;
  select * into registration from app_private.registrations where id = new.registration_id;
  if registration.id is null then return new; end if;

  if old.external_url is distinct from new.external_url and new.external_url is not null
     and new.status = 'awaiting_payment' then
    v_type := 'payment_link_ready';
  elsif old.status is distinct from new.status and new.status = 'reported' then
    v_type := 'payment_reported';
  elsif old.status is distinct from new.status and new.status = 'confirmed' then
    v_type := 'payment_confirmed';
  else
    return new;
  end if;
  v_revision := new.version::text;

  for recipient in
    select distinct users.id, lower(users.email) as email
    from app_private.household_members member
    join auth.users users on users.id = member.user_id and users.email is not null
    where member.household_id = registration.household_id and member.revoked_at is null
  loop
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'payment:' || new.id::text || ':' || v_type || ':' || v_revision || ':' || recipient.id::text,
      v_type, recipient.id::text, recipient.email,
      jsonb_build_object(
        'paymentRequestId',new.id,'paymentVersion',new.version,
        'registrationReference', registration.reference,
        'amountCents', new.amount_cents,
        'paymentStatus', new.status,
        'externalUrl', case when v_type = 'payment_link_ready' then new.external_url else null end,
        'actionPath', '/mijn-inschrijving'
      )
    ) on conflict (dedupe_key) do nothing;
  end loop;
  return new;
end;
$$;


create function api.admin_payment_batch_publish(_event_slug text, _payments jsonb, _external_url text, _reason text, _idempotency_key text, _payer_payment_request_id uuid default null)
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
    or url is null or char_length(url) not between 20 and 1000
    or url !~ '^https://([a-z0-9-]+[.])*tikkie[.]me/[^[:space:]\\]+$'
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

create function api.admin_payment_batch_confirm(_batch_id uuid,_expected_version integer,_amount_cents integer,_external_reference text,_reason text,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid:=auth.uid(); b app_private.payment_link_batches; m record;
  request_hash text; receipt app_private.command_receipts; result jsonb;
begin
  select * into b from app_private.payment_link_batches where id=_batch_id;
  if b.id is null or not (app_private.has_capability(b.event_id,'payments_manage',actor) or app_private.has_capability(b.event_id,'event_admin',actor))
    then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if char_length(trim(coalesce(_reason,''))) not between 5 and 500 or nullif(trim(_external_reference),'') is null
    or char_length(coalesce(_idempotency_key,'')) not between 1 and 200 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  request_hash:=encode(extensions.digest(jsonb_build_object('id',_batch_id,'version',_expected_version,'amount',_amount_cents,'reference',_external_reference,'reason',_reason)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
  select * into receipt from app_private.command_receipts where actor_id=actor and command_type='payment.batchConfirm' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.payment_requests where payment_batch_id=b.id order by id for update;
  select * into b from app_private.payment_link_batches where id=_batch_id for update;
  if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if b.status not in ('awaiting_payment','reported') or app_private.payment_batch_payload(b.id)->>'status'='needs_review'
    then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
  if _amount_cents is distinct from b.total_amount_cents then raise exception 'BATCH_AMOUNT_MISMATCH' using errcode='23514'; end if;
  for m in select bm.*,p.registration_id from app_private.payment_link_batch_members bm join app_private.payment_requests p on p.id=bm.payment_request_id where bm.batch_id=b.id order by p.id loop
    insert into app_private.payment_entries(request_id,amount_cents,entry_type,checked_by,checked_at,external_reference,reason)
    values(m.payment_request_id,m.amount_cents,'payment',actor,now(),trim(_external_reference),trim(_reason));
    update app_private.payment_requests set status='confirmed',version=version+1 where id=m.payment_request_id;
  end loop;
  update app_private.payment_link_batches set status='confirmed',version=version+1,updated_at=now() where id=b.id returning * into b;
  perform app_private.enqueue_payment_batch_email(b.id,'payment_confirmed');
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(b.event_id,actor,'payment.batch_confirmed','payment_batch',b.id,jsonb_build_object('amountCents',_amount_cents,'reason',trim(_reason)));
  result:=app_private.payment_batch_payload(b.id);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
  values(actor,'payment.batchConfirm',_idempotency_key,request_hash,result,now()+interval '1 year');
  return result;
end $$;

create function api.admin_payment_batch_cancel(_batch_id uuid,_expected_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid:=auth.uid(); b app_private.payment_link_batches;
begin
  select * into b from app_private.payment_link_batches where id=_batch_id;
  if b.id is null or not (app_private.has_capability(b.event_id,'payments_manage',actor) or app_private.has_capability(b.event_id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
  perform 1 from app_private.payment_requests where payment_batch_id=b.id order by id for update;
  select * into b from app_private.payment_link_batches where id=_batch_id for update;
  if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if b.status not in ('awaiting_payment','reported') then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
  update app_private.payment_requests set external_url=null,payment_batch_id=null,
    status=case when status in ('awaiting_payment','reported') then 'awaiting_link'::app_private.payment_status else status end, version=version+1
  where payment_batch_id=b.id;
  update app_private.payment_link_batches set status='cancelled',version=version+1,updated_at=now() where id=b.id;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(b.event_id,actor,'payment.batch_cancelled','payment_batch',b.id,jsonb_build_object('reason',trim(_reason)));
  return jsonb_build_object('id',b.id,'status','cancelled');
end $$;

create or replace function api.registration_report_payment(_registration_id uuid,_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid:=auth.uid(); p app_private.payment_requests; b app_private.payment_link_batches; v_event_id uuid;
begin
  select r.event_id into v_event_id from app_private.registrations r
  where r.id=_registration_id and app_private.is_household_member(r.household_id,actor);
  if actor is null or v_event_id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||v_event_id,0));
  select * into p from app_private.payment_requests where registration_id=_registration_id order by created_at desc limit 1;
  if p.payment_batch_id is null then
    select * into p from app_private.payment_requests where id=p.id for update;
    if p.id is null or p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
    if p.status not in ('awaiting_link','awaiting_payment','reported') then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
    if p.status<>'reported' then
      update app_private.payment_requests set status='reported',version=version+1 where id=p.id returning * into p;
      insert into app_private.payment_entries(request_id,amount_cents,entry_type,reason) values(p.id,0,'reported','Gemeld door deelnemer; nog niet gecontroleerd.');
    end if;
  else
    perform 1 from app_private.payment_requests where payment_batch_id=p.payment_batch_id order by id for update;
    select * into p from app_private.payment_requests where id=p.id;
    select * into b from app_private.payment_link_batches where id=p.payment_batch_id for update;
    if not app_private.payment_batch_can_pay(b.id,actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
    if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
    if app_private.payment_batch_payload(b.id)->>'status' not in ('awaiting_payment','reported') then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
    if b.status<>'reported' then
      insert into app_private.payment_entries(request_id,amount_cents,entry_type,reason)
      select pr.id,0,'reported','Gezamenlijke betaling gemeld door deelnemer; nog niet gecontroleerd.' from app_private.payment_requests pr where pr.payment_batch_id=b.id;
      update app_private.payment_requests set status='reported',version=version+1 where payment_batch_id=b.id;
      update app_private.payment_link_batches set status='reported',version=version+1,updated_at=now() where id=b.id;
      perform app_private.enqueue_payment_batch_email(b.id,'payment_reported');
      select * into p from app_private.payment_requests where id=p.id;
    end if;
  end if;
  return jsonb_build_object('status',p.status,'version',p.version);
end $$;

-- Keep every previous privacy-filtered projection intact; add only authorized batch labels.
alter function api.registration_snapshot(text) set schema app_private;
alter function app_private.registration_snapshot(text) rename to registration_snapshot_before_shared_payment;
revoke all on function app_private.registration_snapshot_before_shared_payment(text) from public,anon,authenticated;
create function api.registration_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare snapshot jsonb; p app_private.payment_requests; batch jsonb;
begin
  snapshot:=app_private.registration_snapshot_before_shared_payment(_event_slug);
  if snapshot #>> '{registration,id}' is null then return snapshot; end if;
  select * into p from app_private.payment_requests where registration_id=(snapshot #>> '{registration,id}')::uuid order by created_at desc limit 1;
  if p.id is not null then
    batch:=app_private.payment_batch_payload(p.payment_batch_id);
    snapshot:=jsonb_set(snapshot,'{registration,payment}',(snapshot #> '{registration,payment}') || jsonb_build_object(
      'batch',batch,'externalUrl',case when p.status not in ('awaiting_link','awaiting_payment') then null
        when batch is not null then batch->>'externalUrl' else p.external_url end));
  end if;
  return snapshot;
end $$;

alter function api.admin_payments_snapshot(text) set schema app_private;
alter function app_private.admin_payments_snapshot(text) rename to admin_payments_snapshot_before_shared_payment;
revoke all on function app_private.admin_payments_snapshot_before_shared_payment(text) from public,anon,authenticated;
create function api.admin_payments_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare snapshot jsonb;
begin
  snapshot:=app_private.admin_payments_snapshot_before_shared_payment(_event_slug);
  return coalesce((select jsonb_agg(row.value || jsonb_build_object(
    'parentName',app_private.payment_parent_name(r.id),'parentEmail',u.email,'householdLabel',h.label,
    'groupCode',g.system_code,'groupName',g.display_name,'batch',app_private.payment_batch_payload(p.payment_batch_id)
  ) order by row.ordinality)
  from jsonb_array_elements(snapshot) with ordinality row(value,ordinality)
  join app_private.payment_requests p on p.id=(row.value->>'id')::uuid
  join app_private.registrations r on r.id=p.registration_id
  join app_private.households h on h.id=r.household_id
  left join auth.users u on u.id=h.primary_contact_user_id
  left join lateral (select wg.system_code,wg.display_name from app_private.group_registrations gr
    join app_private.walking_groups wg on wg.id=gr.group_id
    where gr.registration_id=r.id and gr.superseded_at is null order by gr.published_at desc nulls last limit 1) g on true),'[]'::jsonb);
end $$;

alter function api.payment_set_external_link(uuid,integer,text,text) set schema app_private;
alter function app_private.payment_set_external_link(uuid,integer,text,text) rename to payment_set_external_link_before_shared;
revoke all on function app_private.payment_set_external_link_before_shared(uuid,integer,text,text) from public,anon,authenticated;
create function api.payment_set_external_link(_payment_request_id uuid,_expected_version integer,_external_url text,_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p app_private.payment_requests; v_event_id uuid;
begin
  select r.event_id into v_event_id from app_private.payment_requests pr join app_private.registrations r on r.id=pr.registration_id where pr.id=_payment_request_id;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'payments_manage') or app_private.has_capability(v_event_id,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||v_event_id,0));
  select * into p from app_private.payment_requests where id=_payment_request_id for update;
  if p.payment_batch_id is not null then raise exception 'SHARED_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
  return app_private.payment_set_external_link_before_shared(_payment_request_id,_expected_version,_external_url,_reason);
end $$;
revoke all on function api.payment_set_external_link(uuid,integer,text,text) from public,anon;
grant execute on function api.payment_set_external_link(uuid,integer,text,text) to authenticated;

alter function api.payment_confirm_versioned(uuid,integer,integer,text,text,text,text) set schema app_private;
alter function app_private.payment_confirm_versioned(uuid,integer,integer,text,text,text,text) rename to payment_confirm_versioned_before_shared;
revoke all on function app_private.payment_confirm_versioned_before_shared(uuid,integer,integer,text,text,text,text) from public,anon,authenticated;
create function api.payment_confirm_versioned(_payment_request_id uuid,_expected_version integer,_amount_cents integer,_external_reference text,_reason text,_idempotency_key text,_request_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p app_private.payment_requests; v_event_id uuid;
begin
  select r.event_id into v_event_id from app_private.payment_requests pr join app_private.registrations r on r.id=pr.registration_id where pr.id=_payment_request_id;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'payments_manage') or app_private.has_capability(v_event_id,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||v_event_id,0));
  select * into p from app_private.payment_requests where id=_payment_request_id for update;
  if p.payment_batch_id is not null then raise exception 'SHARED_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
  return app_private.payment_confirm_versioned_before_shared(_payment_request_id,_expected_version,_amount_cents,_external_reference,_reason,_idempotency_key,_request_hash);
end $$;
revoke all on function api.payment_confirm_versioned(uuid,integer,integer,text,text,text,text) from public,anon;
grant execute on function api.payment_confirm_versioned(uuid,integer,integer,text,text,text,text) to authenticated;

alter function api.payment_confirm(uuid,integer,text,text,text,text) set schema app_private;
alter function app_private.payment_confirm(uuid,integer,text,text,text,text) rename to payment_confirm_before_shared;
revoke all on function app_private.payment_confirm_before_shared(uuid,integer,text,text,text,text) from public,anon,authenticated;
create function api.payment_confirm(_payment_request_id uuid,_amount_cents integer,_external_reference text,_reason text,_idempotency_key text,_request_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p app_private.payment_requests; v_event_id uuid;
begin
  select r.event_id into v_event_id from app_private.payment_requests pr join app_private.registrations r on r.id=pr.registration_id where pr.id=_payment_request_id;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'payments_manage') or app_private.has_capability(v_event_id,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||v_event_id,0));
  select * into p from app_private.payment_requests where id=_payment_request_id for update;
  if p.payment_batch_id is not null then raise exception 'SHARED_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
  return app_private.payment_confirm_before_shared(_payment_request_id,_amount_cents,_external_reference,_reason,_idempotency_key,_request_hash);
end $$;
revoke all on function api.payment_confirm(uuid,integer,text,text,text,text) from public,anon;
revoke all on function api.payment_confirm(uuid,integer,text,text,text,text) from authenticated;

revoke all on function app_private.payment_parent_name(uuid),app_private.payment_batch_payload(uuid),app_private.enqueue_payment_batch_email(uuid,text) from public,anon,authenticated;
revoke all on function api.admin_payment_batch_publish(text,jsonb,text,text,text,uuid),api.admin_payment_batch_confirm(uuid,integer,integer,text,text,text),api.admin_payment_batch_cancel(uuid,integer,text),api.registration_snapshot(text),api.admin_payments_snapshot(text) from public,anon;
grant execute on function api.admin_payment_batch_publish(text,jsonb,text,text,text,uuid),api.admin_payment_batch_confirm(uuid,integer,integer,text,text,text),api.admin_payment_batch_cancel(uuid,integer,text),api.registration_snapshot(text),api.admin_payments_snapshot(text) to authenticated;
select pg_notify('pgrst','reload schema');

revoke all on function app_private.payment_batch_can_pay(uuid,uuid) from public,anon,authenticated;

-- Delayed mail must not ask for payment of a corrected, cancelled or settled link.
alter function api.worker_claim_outbox(integer,integer) set schema app_private;
alter function app_private.worker_claim_outbox(integer,integer) rename to worker_claim_outbox_before_shared;
revoke all on function app_private.worker_claim_outbox_before_shared(integer,integer) from public,anon,authenticated,service_role;
create function api.worker_claim_outbox(_batch_size integer,_lease_seconds integer)
returns setof app_private.email_outbox language plpgsql security definer set search_path = '' as $$
begin
  update app_private.email_outbox o set status='suppressed',last_error_code='PAYMENT_LINK_SUPERSEDED'
  where o.status in ('pending','deferred') and o.message_type='payment_link_ready' and (
    (o.payload ? 'batchId' and not exists(select 1 from app_private.payment_link_batches b
      where b.id::text=o.payload->>'batchId' and b.version::text=o.payload->>'batchVersion'
        and b.status='awaiting_payment' and b.external_url=o.payload->>'externalUrl'
        and app_private.payment_batch_payload(b.id)->>'status'='awaiting_payment'
        and exists(select 1 from app_private.payment_requests p join app_private.registrations r on r.id=p.registration_id
          join app_private.household_members hm on hm.household_id=r.household_id and hm.revoked_at is null
          where p.id=b.payer_payment_request_id and hm.user_id::text=o.recipient_ref)))
    or (o.payload ? 'paymentRequestId' and not exists(select 1 from app_private.payment_requests p
      where p.id::text=o.payload->>'paymentRequestId' and p.version::text=o.payload->>'paymentVersion'
        and p.status='awaiting_payment' and p.payment_batch_id is null and p.external_url=o.payload->>'externalUrl'))
  );
  return query select * from app_private.worker_claim_outbox_before_shared(_batch_size,_lease_seconds);
end $$;
revoke all on function api.worker_claim_outbox(integer,integer) from public,anon,authenticated;
grant execute on function api.worker_claim_outbox(integer,integer) to service_role;
