-- Tikkies select individual children; registration ledgers remain the accounting total.
create table app_private.child_payment_batches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id),
  anchor_child_id uuid not null references app_private.children(id),
  external_url text not null,
  total_amount_cents integer not null check(total_amount_cents>0),
  status text not null default 'awaiting_payment' check(status in ('awaiting_payment','reported','confirmed','cancelled','refunded')),
  version integer not null default 1,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index child_payment_batches_event_idx on app_private.child_payment_batches(event_id);
create index child_payment_batches_anchor_idx on app_private.child_payment_batches(anchor_child_id);
create index child_payment_batches_creator_idx on app_private.child_payment_batches(created_by);
alter table app_private.registration_children add column child_payment_batch_id uuid references app_private.child_payment_batches(id), add column payment_version integer not null default 1;
create index registration_children_payment_batch_idx on app_private.registration_children(child_payment_batch_id) where child_payment_batch_id is not null;
alter table app_private.payment_requests add column child_payment_mode boolean not null default false;
alter table app_private.payment_entries add column child_payment_batch_id uuid references app_private.child_payment_batches(id);
create unique index payment_entries_child_batch_once_idx on app_private.payment_entries(request_id,child_payment_batch_id,entry_type) where child_payment_batch_id is not null;
create index payment_entries_child_batch_idx on app_private.payment_entries(child_payment_batch_id) where child_payment_batch_id is not null;
create table app_private.child_payment_members (
  batch_id uuid not null references app_private.child_payment_batches(id),
  registration_child_id uuid not null references app_private.registration_children(id),
  payment_request_id uuid not null references app_private.payment_requests(id),
  amount_cents integer not null check(amount_cents>0),
  primary key(batch_id,registration_child_id)
);
create index child_payment_members_child_idx on app_private.child_payment_members(registration_child_id);
create index child_payment_members_request_idx on app_private.child_payment_members(payment_request_id);
alter table app_private.child_payment_batches enable row level security;
alter table app_private.child_payment_members enable row level security;
revoke all on app_private.child_payment_batches,app_private.child_payment_members from public,anon,authenticated;

create function app_private.child_payment_can_pay(_id uuid,_actor uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((select app_private.is_household_member(c.household_id,_actor) from app_private.child_payment_batches b join app_private.children c on c.id=b.anchor_child_id where b.id=_id),false)
$$;
create function app_private.child_payment_batch_payload(_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b app_private.child_payment_batches; s text;
begin
 select * into b from app_private.child_payment_batches where id=_id;
 if b.id is null then return null; end if;
 s:=b.status;
 if b.status not in('cancelled','refunded') and exists(
   select 1 from app_private.child_payment_members m
   join app_private.registration_children rc on rc.id=m.registration_child_id
   join app_private.registrations r on r.id=rc.registration_id
   join app_private.payment_requests p on p.id=m.payment_request_id
   where m.batch_id=b.id and ((b.status<>'confirmed' and (rc.child_payment_batch_id is distinct from b.id or rc.unit_price_cents<>m.amount_cents
     or rc.participation_status<>'active' or r.status='cancelled' or not p.child_payment_mode
     or p.amount_cents<>(select coalesce(sum(x.unit_price_cents),0) from app_private.registration_children x where x.registration_id=r.id and x.participation_status='active')))
     or (select coalesce(sum(e.amount_cents),0) from app_private.payment_entries e where e.request_id=p.id and e.entry_type<>'reported')
       <> (select coalesce(sum(cm.amount_cents),0) from app_private.child_payment_members cm join app_private.child_payment_batches cb on cb.id=cm.batch_id where cm.payment_request_id=p.id and cb.status='confirmed'))
 ) then s:='needs_review'; end if;
 return jsonb_build_object('id',b.id,'version',b.version,'status',s,'totalAmountCents',b.total_amount_cents,
   'anchorChildId',b.anchor_child_id,'anchorChildName',(select first_name from app_private.children where id=b.anchor_child_id),
   'canPay',app_private.child_payment_can_pay(b.id),
   'externalUrl',case when s='awaiting_payment' and (app_private.child_payment_can_pay(b.id) or app_private.has_capability(b.event_id,'payments_manage') or app_private.has_capability(b.event_id,'event_admin')) then b.external_url end,
   'childNames',(select jsonb_agg(c.first_name order by rc.created_at,c.id) from app_private.child_payment_members m join app_private.registration_children rc on rc.id=m.registration_child_id join app_private.children c on c.id=rc.child_id where m.batch_id=b.id));
end $$;

create function app_private.child_payment_payload(_registration_child_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rc app_private.registration_children; p app_private.payment_requests; b jsonb; anchor uuid; s text;
begin
 select * into rc from app_private.registration_children where id=_registration_child_id;
 select * into p from app_private.payment_requests where registration_id=rc.registration_id order by created_at desc limit 1;
 if rc.child_payment_batch_id is not null then
   b:=app_private.child_payment_batch_payload(rc.child_payment_batch_id); s:=b->>'status';
 elsif p.child_payment_mode then s:='awaiting_link';
 else
   s:=coalesce(p.status::text,'awaiting_link');
   if p.payment_batch_id is not null then
     b:=app_private.payment_batch_payload(p.payment_batch_id);
     select rcc.child_id into anchor from app_private.registration_children rcc join app_private.payment_requests pp on pp.registration_id=rcc.registration_id
     where pp.id=(b->>'payerPaymentRequestId')::uuid and rcc.participation_status='active' order by rcc.created_at,rcc.child_id limit 1;
     b:=b||jsonb_build_object('legacy',true,'anchorChildId',anchor,'anchorChildName',(select first_name from app_private.children where id=anchor),
       'childNames',(select jsonb_agg(c.first_name order by c.id) from app_private.payment_link_batch_members m join app_private.payment_requests pp on pp.id=m.payment_request_id join app_private.registration_children rcc on rcc.registration_id=pp.registration_id join app_private.children c on c.id=rcc.child_id where m.batch_id=p.payment_batch_id and rcc.participation_status='active'));
     s:=b->>'status';
   elsif p.external_url is not null then
     select child_id into anchor from app_private.registration_children where registration_id=rc.registration_id and participation_status='active' order by created_at,child_id limit 1;
     b:=jsonb_build_object('id',p.id,'legacy',true,'version',p.version,'status',s,'totalAmountCents',p.amount_cents,
       'anchorChildId',anchor,'anchorChildName',(select first_name from app_private.children where id=anchor),'canPay',true,
       'externalUrl',case when s='awaiting_payment' then p.external_url end,
       'childNames',(select jsonb_agg(c.first_name order by c.id) from app_private.registration_children rcc join app_private.children c on c.id=rcc.child_id where rcc.registration_id=rc.registration_id and rcc.participation_status='active'));
   end if;
 end if;
 if rc.participation_status<>'active' then s:='cancelled'; elsif rc.unit_price_cents=0 then s:='waived'; end if;
 return jsonb_build_object('status',s,'version',rc.payment_version,'batch',b);
end $$;

create function app_private.enqueue_child_payment_email(_id uuid,_type text) returns void
language plpgsql security definer set search_path='' as $$
declare b app_private.child_payment_batches; recipient record; payload jsonb;
begin
 select * into b from app_private.child_payment_batches where id=_id;
 payload:=app_private.child_payment_batch_payload(b.id);
 for recipient in select distinct u.id,lower(u.email) email from app_private.child_payment_members m
   join app_private.registration_children rc on rc.id=m.registration_child_id
   join app_private.registrations r on r.id=rc.registration_id
   join app_private.household_members hm on hm.household_id=r.household_id and hm.revoked_at is null
   join auth.users u on u.id=hm.user_id and u.email is not null
   where m.batch_id=b.id and (_type<>'payment_link_ready' or rc.child_id=b.anchor_child_id)
 loop
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('child-payment:'||b.id||':'||b.version||':'||_type||':'||recipient.id,_type,recipient.id::text,recipient.email,
     jsonb_build_object('childBatchId',b.id,'childBatchVersion',b.version,'amountCents',b.total_amount_cents,
       'externalUrl',case when _type='payment_link_ready' then b.external_url end,
       'paymentChildren',payload->'childNames','anchorChildName',payload->>'anchorChildName','actionPath','/omgeving/meeloper/nachtpas'))
   on conflict(dedupe_key) do nothing;
 end loop;
end $$;

create function api.admin_child_payment_publish(_event_slug text,_children jsonb,_anchor_child_id uuid,_external_url text,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; rc app_private.registration_children; p app_private.payment_requests; item record;
 b app_private.child_payment_batches; existing uuid; total integer:=0; receipt app_private.command_receipts; hash text; result jsonb; url text:=trim(_external_url);
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or not(app_private.has_capability(eid,'payments_manage',actor) or app_private.has_capability(eid,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _children is null or jsonb_typeof(_children)<>'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if jsonb_array_length(_children) not between 1 and 100 or url is null or char_length(url) not between 20 and 1000 or url !~ '^https://([a-z0-9-]+[.])*tikkie[.]me/[^[:space:]\\]+$'
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

create function api.admin_child_payment_confirm(_batch_id uuid,_expected_version integer,_amount_cents integer,_external_reference text,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); b app_private.child_payment_batches; m record; receipt app_private.command_receipts; hash text; result jsonb; collected integer;
begin
 select * into b from app_private.child_payment_batches where id=_batch_id;
 if b.id is null or not(app_private.has_capability(b.event_id,'payments_manage',actor) or app_private.has_capability(b.event_id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 5 and 500 or nullif(trim(_external_reference),'') is null or char_length(coalesce(_idempotency_key,'')) not between 1 and 200 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 hash:=encode(extensions.digest(jsonb_build_object('id',_batch_id,'version',_expected_version,'amount',_amount_cents,'reference',_external_reference,'reason',_reason)::text,'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='payment.childConfirm' and idempotency_key=_idempotency_key;
 if receipt.id is not null then
   if receipt.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if; return receipt.safe_result;
 end if;
 perform 1 from app_private.payment_requests where id in(select payment_request_id from app_private.child_payment_members where batch_id=b.id) order by id for update;
 perform 1 from app_private.registration_children where child_payment_batch_id=b.id order by child_id for update;
 select * into b from app_private.child_payment_batches where id=_batch_id for update;
 if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if b.status not in('awaiting_payment','reported') or app_private.child_payment_batch_payload(b.id)->>'status'='needs_review' then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
 if _amount_cents is distinct from b.total_amount_cents then raise exception 'BATCH_AMOUNT_MISMATCH' using errcode='23514'; end if;
 for m in select payment_request_id,sum(amount_cents)::integer amount from app_private.child_payment_members where batch_id=b.id group by payment_request_id order by payment_request_id loop
   insert into app_private.payment_entries(request_id,amount_cents,entry_type,checked_by,checked_at,external_reference,reason,child_payment_batch_id) values(m.payment_request_id,m.amount,'payment',actor,now(),trim(_external_reference),trim(_reason),b.id);
   select coalesce(sum(amount_cents),0) into collected from app_private.payment_entries where request_id=m.payment_request_id and entry_type<>'reported';
   update app_private.payment_requests set status=case when collected=amount_cents then 'confirmed'::app_private.payment_status when collected<amount_cents then 'partial'::app_private.payment_status else 'refund_due'::app_private.payment_status end,version=version+1 where id=m.payment_request_id;
 end loop;
 update app_private.child_payment_batches set status='confirmed',version=version+1 where id=b.id returning * into b;
 update app_private.registration_children set payment_version=payment_version+1 where child_payment_batch_id=b.id;
 perform app_private.enqueue_child_payment_email(b.id,'payment_confirmed');
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(b.event_id,actor,'payment.child_confirmed','child_payment_batch',b.id,jsonb_build_object('amountCents',_amount_cents,'reason',_reason));
 result:=app_private.child_payment_batch_payload(b.id);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'payment.childConfirm',_idempotency_key,hash,result,now()+interval '1 year'); return result;
end $$;

create function api.child_payment_report(_batch_id uuid,_expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b app_private.child_payment_batches;
begin
 select * into b from app_private.child_payment_batches where id=_batch_id;
 if b.id is null or not app_private.child_payment_can_pay(b.id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
 perform 1 from app_private.payment_requests where id in(select payment_request_id from app_private.child_payment_members where batch_id=b.id) order by id for update;
 perform 1 from app_private.registration_children where child_payment_batch_id=b.id order by child_id for update;
 select * into b from app_private.child_payment_batches where id=_batch_id for update;
 if not app_private.child_payment_can_pay(b.id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if b.status not in('awaiting_payment','reported') or app_private.child_payment_batch_payload(b.id)->>'status'='needs_review' then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
 if b.status='awaiting_payment' then
   update app_private.child_payment_batches set status='reported',version=version+1 where id=b.id returning * into b;
   update app_private.registration_children set payment_version=payment_version+1 where child_payment_batch_id=b.id;
   perform app_private.enqueue_child_payment_email(b.id,'payment_reported');
   insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(b.event_id,auth.uid(),'payment.child_reported','child_payment_batch',b.id,'{}');
 end if;
 return app_private.child_payment_batch_payload(b.id);
end $$;

create function api.admin_child_payment_cancel(_batch_id uuid,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b app_private.child_payment_batches;
begin
 select * into b from app_private.child_payment_batches where id=_batch_id;
 if b.id is null or not(app_private.has_capability(b.event_id,'payments_manage') or app_private.has_capability(b.event_id,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
 perform 1 from app_private.payment_requests where id in(select payment_request_id from app_private.child_payment_members where batch_id=b.id) order by id for update;
 perform 1 from app_private.registration_children where child_payment_batch_id=b.id order by child_id for update;
 select * into b from app_private.child_payment_batches where id=_batch_id for update;
 if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if b.status not in('awaiting_payment','reported') then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
 update app_private.child_payment_batches set status='cancelled',version=version+1 where id=b.id returning * into b;
 update app_private.registration_children set child_payment_batch_id=null,payment_version=payment_version+1 where child_payment_batch_id=b.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(b.event_id,auth.uid(),'payment.child_cancelled','child_payment_batch',b.id,jsonb_build_object('reason',_reason));
 return app_private.child_payment_batch_payload(b.id);
end $$;

alter function api.registration_snapshot(text) set schema app_private;
alter function app_private.registration_snapshot(text) rename to registration_snapshot_before_child_payments;
revoke all on function app_private.registration_snapshot_before_child_payments(text) from public,anon,authenticated;
create function api.registration_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; enriched jsonb;
begin
 result:=app_private.registration_snapshot_before_child_payments(_event_slug);
 if result #>> '{registration,id}' is null then return result; end if;
 select coalesce(jsonb_agg(x.value||jsonb_build_object('childId',rc.child_id,'payment',app_private.child_payment_payload(rc.id)) order by x.ordinality),'[]'::jsonb) into enriched
 from jsonb_array_elements(result #> '{registration,children}') with ordinality x(value,ordinality)
 join app_private.registration_children rc on rc.id=(x.value->>'id')::uuid and rc.registration_id=(result #>> '{registration,id}')::uuid;
 return jsonb_set(result,'{registration,children}',enriched);
end $$;

create function api.admin_child_payments_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or not(app_private.has_capability(eid,'payments_manage') or app_private.has_capability(eid,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('childId',c.id,'firstName',c.first_name,'registrationId',r.id,'registrationReference',r.reference,
   'parentName',app_private.payment_parent_name(r.id),'parentEmail',u.email,'groupCode',g.system_code,'groupName',g.display_name,
   'amountCents',rc.unit_price_cents)||app_private.child_payment_payload(rc.id) order by r.created_at,c.created_at,c.id)
 from app_private.registration_children rc join app_private.children c on c.id=rc.child_id join app_private.registrations r on r.id=rc.registration_id
 join app_private.households h on h.id=r.household_id left join auth.users u on u.id=h.primary_contact_user_id
 left join lateral(select wg.system_code,wg.display_name from app_private.group_registrations gr join app_private.walking_groups wg on wg.id=gr.group_id where gr.registration_id=r.id and gr.superseded_at is null order by gr.published_at desc nulls last limit 1) g on true
 where rc.event_id=eid),'[]'::jsonb);
end $$;

-- Legacy APIs must not collect a child's invoice a second time at registration level.
create function app_private.guard_child_payment_ledger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.entry_type in('payment','refund') and new.child_payment_batch_id is null and exists(select 1 from app_private.payment_requests where id=new.request_id and child_payment_mode) then raise exception 'CHILD_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
 return new;
end $$;
create trigger guard_child_payment_ledger before insert on app_private.payment_entries for each row execute function app_private.guard_child_payment_ledger();
create function app_private.guard_child_payment_request() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.child_payment_mode and (new.external_url is not null or new.payment_batch_id is not null or new.status='reported') then raise exception 'CHILD_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
 return new;
end $$;
create trigger guard_child_payment_request before update on app_private.payment_requests for each row execute function app_private.guard_child_payment_request();
create function app_private.touch_child_payment_version() returns trigger
language plpgsql set search_path='' as $$
begin
 if old.participation_status is distinct from new.participation_status or old.unit_price_cents is distinct from new.unit_price_cents then new.payment_version:=old.payment_version+1; end if;
 return new;
end $$;
create trigger touch_child_payment_version before update on app_private.registration_children for each row execute function app_private.touch_child_payment_version();

-- An organizer can explicitly withdraw an old whole-registration link before splitting it.
create function api.admin_child_payment_clear_legacy(_registration_id uuid,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.registrations; p app_private.payment_requests;
begin
 select * into r from app_private.registrations where id=_registration_id;
 if r.id is null or not(app_private.has_capability(r.event_id,'payments_manage') or app_private.has_capability(r.event_id,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||r.event_id,0));
 select * into p from app_private.payment_requests where registration_id=r.id order by created_at desc limit 1 for update;
 if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if p.payment_batch_id is not null then raise exception 'SHARED_PAYMENT_REQUIRES_BATCH' using errcode='23514'; end if;
 if p.child_payment_mode or p.status not in('awaiting_link','awaiting_payment','reported') or exists(select 1 from app_private.payment_entries where request_id=p.id and entry_type<>'reported' and amount_cents<>0) then raise exception 'INVALID_TRANSITION' using errcode='23514'; end if;
 update app_private.payment_requests set external_url=null,status='awaiting_link',version=version+1 where id=p.id;
 update app_private.registration_children set payment_version=payment_version+1 where registration_id=r.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(r.event_id,auth.uid(),'payment.legacy_link_withdrawn','payment_request',p.id,jsonb_build_object('reason',_reason));
 return jsonb_build_object('status','awaiting_link');
end $$;

alter function api.worker_claim_outbox(integer,integer) set schema app_private;
alter function app_private.worker_claim_outbox(integer,integer) rename to worker_claim_outbox_before_children;
revoke all on function app_private.worker_claim_outbox_before_children(integer,integer) from public,anon,authenticated,service_role;
create function api.worker_claim_outbox(_batch_size integer,_lease_seconds integer) returns setof app_private.email_outbox
language plpgsql security definer set search_path='' as $$
begin
 update app_private.email_outbox o set status='suppressed',last_error_code='PAYMENT_LINK_SUPERSEDED'
 where o.status in('pending','deferred') and o.message_type='payment_link_ready' and o.payload ? 'childBatchId'
 and not exists(select 1 from app_private.child_payment_batches b where b.id::text=o.payload->>'childBatchId' and b.version::text=o.payload->>'childBatchVersion'
   and b.external_url=o.payload->>'externalUrl' and app_private.child_payment_batch_payload(b.id)->>'status'='awaiting_payment'
   and app_private.child_payment_can_pay(b.id,o.recipient_ref::uuid));
 return query select * from app_private.worker_claim_outbox_before_children(_batch_size,_lease_seconds);
end $$;
revoke all on function api.worker_claim_outbox(integer,integer) from public,anon,authenticated;
grant execute on function api.worker_claim_outbox(integer,integer) to service_role;

revoke all on function app_private.child_payment_can_pay(uuid,uuid),app_private.child_payment_batch_payload(uuid),app_private.child_payment_payload(uuid),app_private.enqueue_child_payment_email(uuid,text),app_private.guard_child_payment_ledger(),app_private.guard_child_payment_request(),app_private.touch_child_payment_version() from public,anon,authenticated;
revoke all on function api.registration_snapshot(text),api.admin_child_payments_snapshot(text),api.admin_child_payment_publish(text,jsonb,uuid,text,text,text),api.admin_child_payment_confirm(uuid,integer,integer,text,text,text),api.child_payment_report(uuid,integer),api.admin_child_payment_cancel(uuid,integer,text),api.admin_child_payment_clear_legacy(uuid,integer,text) from public,anon;
grant execute on function api.registration_snapshot(text),api.admin_child_payments_snapshot(text),api.admin_child_payment_publish(text,jsonb,uuid,text,text,text),api.admin_child_payment_confirm(uuid,integer,integer,text,text,text),api.child_payment_report(uuid,integer),api.admin_child_payment_cancel(uuid,integer,text),api.admin_child_payment_clear_legacy(uuid,integer,text) to authenticated;

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
  if new.registration_id is null or new.payment_batch_id is not null or new.child_payment_mode then return new; end if;
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



alter function api.admin_payments_snapshot(text) set schema app_private;
alter function app_private.admin_payments_snapshot(text) rename to admin_payments_snapshot_before_children;
revoke all on function app_private.admin_payments_snapshot_before_children(text) from public,anon,authenticated;
create function api.admin_payments_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.admin_payments_snapshot_before_children(_event_slug);
 return coalesce((select jsonb_agg(x.value||jsonb_build_object('childPaymentMode',p.child_payment_mode,'registrationId',p.registration_id) order by x.ordinality) from jsonb_array_elements(result) with ordinality x(value,ordinality) join app_private.payment_requests p on p.id=(x.value->>'id')::uuid),'[]'::jsonb);
end $$;
revoke all on function api.admin_payments_snapshot(text) from public,anon;
grant execute on function api.admin_payments_snapshot(text) to authenticated;

-- Records an externally executed refund for this exact Tikkie; never moves money.
create function api.admin_child_payment_refund(_batch_id uuid,_expected_version integer,_amount_cents integer,_external_reference text,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); b app_private.child_payment_batches; m record; receipt app_private.command_receipts; hash text; result jsonb; collected integer;
begin
 select * into b from app_private.child_payment_batches where id=_batch_id;
 if b.id is null or not(app_private.has_capability(b.event_id,'payments_manage',actor) or app_private.has_capability(b.event_id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 5 and 500 or nullif(trim(_external_reference),'') is null or char_length(coalesce(_idempotency_key,'')) not between 1 and 200 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 hash:=encode(extensions.digest(jsonb_build_object('id',_batch_id,'version',_expected_version,'amount',_amount_cents,'reference',_external_reference,'reason',_reason)::text,'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||b.event_id,0));
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='payment.childRefund' and idempotency_key=_idempotency_key;
 if receipt.id is not null then
   if receipt.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if; return receipt.safe_result;
 end if;
 perform 1 from app_private.payment_requests where id in(select payment_request_id from app_private.child_payment_members where batch_id=b.id) order by id for update;
 perform 1 from app_private.registration_children where child_payment_batch_id=b.id order by child_id for update;
 select * into b from app_private.child_payment_batches where id=_batch_id for update;
 if b.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if b.status<>'confirmed' or app_private.child_payment_batch_payload(b.id)->>'status'='needs_review' then raise exception 'BATCH_NEEDS_REVIEW' using errcode='23514'; end if;
 if _amount_cents is distinct from b.total_amount_cents then raise exception 'BATCH_AMOUNT_MISMATCH' using errcode='23514'; end if;
 for m in select payment_request_id,sum(amount_cents)::integer amount from app_private.child_payment_members where batch_id=b.id group by payment_request_id order by payment_request_id loop
   insert into app_private.payment_entries(request_id,amount_cents,entry_type,checked_by,checked_at,external_reference,reason,child_payment_batch_id) values(m.payment_request_id,-m.amount,'refund',actor,now(),trim(_external_reference),trim(_reason),b.id);
   select coalesce(sum(amount_cents),0) into collected from app_private.payment_entries where request_id=m.payment_request_id and entry_type<>'reported';
   update app_private.payment_requests set status=case when amount_cents=0 and collected=0 then 'waived'::app_private.payment_status when collected=amount_cents then 'confirmed'::app_private.payment_status when collected>amount_cents then 'refund_due'::app_private.payment_status when collected>0 then 'partial'::app_private.payment_status else 'awaiting_link'::app_private.payment_status end,version=version+1 where id=m.payment_request_id;
 end loop;
 update app_private.child_payment_batches set status='refunded',version=version+1 where id=b.id returning * into b;
 update app_private.registration_children set child_payment_batch_id=null,payment_version=payment_version+1 where child_payment_batch_id=b.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(b.event_id,actor,'payment.child_refunded','child_payment_batch',b.id,jsonb_build_object('amountCents',_amount_cents,'reason',_reason));
 result:=app_private.child_payment_batch_payload(b.id);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'payment.childRefund',_idempotency_key,hash,result,now()+interval '1 year'); return result;
end $$;
revoke all on function api.admin_child_payment_refund(uuid,integer,integer,text,text,text) from public,anon;
grant execute on function api.admin_child_payment_refund(uuid,integer,integer,text,text,text) to authenticated;

-- Registration edits lock children before invoices in the existing workflow. Take
-- the shared event mutex before either workflow locks rows, avoiding a lock cycle.
alter function api.admin_decide_registration_change(uuid,integer,text,text) set schema app_private;
alter function app_private.admin_decide_registration_change(uuid,integer,text,text) rename to admin_decide_registration_change_before_child_payments;
revoke all on function app_private.admin_decide_registration_change_before_child_payments(uuid,integer,text,text) from public,anon,authenticated;
create function api.admin_decide_registration_change(_case_id uuid,_expected_case_version integer,_decision text,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 select event_id into eid from app_private.support_cases where id=_case_id;
 if app_private.has_capability(eid,'event_admin') or app_private.has_capability(eid,'registration_manage') then
   perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||eid,0));
 end if;
 return app_private.admin_decide_registration_change_before_child_payments(_case_id,_expected_case_version,_decision,_reason);
end $$;
revoke all on function api.admin_decide_registration_change(uuid,integer,text,text) from public,anon;
grant execute on function api.admin_decide_registration_change(uuid,integer,text,text) to authenticated;
