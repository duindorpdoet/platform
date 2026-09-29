begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(
  not has_function_privilege(
    'anon',
    'api.admin_group_repair_split_party(text,uuid)',
    'execute'
  ),
  'anonymous clients cannot repair split together parties'
);

create function pg_temp.fixture_split_party(_members integer default 4)
returns uuid
language plpgsql
as $$
declare
  party_id uuid := gen_random_uuid();
  household_id uuid;
  registration_id uuid;
  child_id uuid;
  event_id uuid := (
    select id from app_private.events where slug = 'duindorp-halloween-2026'
  );
begin
  for member_number in 1.._members loop
    insert into app_private.households(label, primary_contact_user_id)
    values (
      'Correctiegezin ' || member_number,
      'f0000000-0000-0000-0000-000000000001'
    ) returning id into household_id;
    insert into app_private.household_members(household_id, user_id, relation_role)
    values (
      household_id,
      'f0000000-0000-0000-0000-000000000001',
      'owner'
    );
    insert into app_private.registrations(
      event_id,
      household_id,
      status,
      reference,
      submitted_at
    ) values (
      event_id,
      household_id,
      'submitted',
      'DPH-REPAIR-' || member_number,
      now()
    ) returning id into registration_id;
    if member_number = 1 then
      insert into app_private.together_parties(
        id,
        event_id,
        public_label,
        creator_household_id,
        invite_token_hash,
        expires_at
      ) values (
        party_id,
        event_id,
        'Correctie samenloop',
        household_id,
        extensions.gen_random_bytes(32),
        now() + interval '1 year'
      );
    end if;
    insert into app_private.children(household_id, first_name, age_at_event)
    values (household_id, 'Correctiekind ' || member_number, 8)
    returning id into child_id;
    insert into app_private.registration_children(
      event_id,
      registration_id,
      child_id,
      unit_price_cents
    ) values (event_id, registration_id, child_id, 250);
    insert into app_private.together_memberships(party_id, registration_id)
    values (party_id, registration_id);
  end loop;
  return party_id;
end;
$$;

create temp table repair_fixture(party_id uuid primary key);
insert into repair_fixture values (pg_temp.fixture_split_party());
create temp table repair_groups(name text primary key, id uuid not null);
create temp table repair_result(value jsonb);
with created as (
  insert into app_private.walking_groups(
    event_id,
    code,
    status,
    display_name,
    route_mode
  )
  select id, 'pending', 'draft', 'Meerderheid', 'dynamic'
  from app_private.events
  where slug = 'duindorp-halloween-2026'
  returning id
)
insert into repair_groups select 'majority', id from created;
with created as (
  insert into app_private.walking_groups(
    event_id,
    code,
    status,
    display_name,
    route_mode
  )
  select id, 'pending', 'draft', 'Minderheid', 'dynamic'
  from app_private.events
  where slug = 'duindorp-halloween-2026'
  returning id
)
insert into repair_groups select 'minority', id from created;
grant select on repair_fixture, repair_groups, repair_result to authenticated;
grant insert on repair_result to authenticated;

with ranked_members as (
  select
    membership.registration_id,
    row_number() over (order by membership.registration_id) as position
  from app_private.together_memberships membership
  where membership.party_id = (select party_id from repair_fixture)
    and membership.left_at is null
)
insert into app_private.group_registrations(
  group_id,
  registration_id,
  assignment_revision
)
select
  case
    when position <= 2 then (select id from repair_groups where name = 'majority')
    else (select id from repair_groups where name = 'minority')
  end,
  registration_id,
  1
from ranked_members
where position <= 3;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select api.admin_group_repair_split_party(
    'duindorp-halloween-2026',
    (select party_id from repair_fixture)
  )$$,
  '42501',
  'NOT_AUTHORIZED',
  'participants cannot repair organizer group assignments'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
insert into repair_result
select api.admin_group_repair_split_party(
  'duindorp-halloween-2026',
  (select party_id from repair_fixture)
);
reset role;
select is(
  (select value ->> 'targetGroupId' from repair_result),
  (select id::text from repair_groups where name = 'majority'),
  'the server selects the group containing the most party registrations'
);
select is(
  (select value ->> 'movedRegistrations' from repair_result),
  '4',
  'the correction reports the complete together party'
);
select is(
  (
    select count(distinct assignment.group_id)
    from app_private.group_registrations assignment
    join app_private.together_memberships membership
      on membership.registration_id = assignment.registration_id
     and membership.left_at is null
    where membership.party_id = (select party_id from repair_fixture)
      and assignment.superseded_at is null
  ),
  1::bigint,
  'the together party has one active group after correction'
);
select is(
  (
    select count(*)
    from app_private.group_registrations assignment
    join app_private.together_memberships membership
      on membership.registration_id = assignment.registration_id
     and membership.left_at is null
    where membership.party_id = (select party_id from repair_fixture)
      and assignment.group_id = (select id from repair_groups where name = 'majority')
      and assignment.superseded_at is null
  ),
  4::bigint,
  'assigned and unassigned party members all land in the majority group'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select api.admin_group_repair_split_party(
    'duindorp-halloween-2026',
    (select party_id from repair_fixture)
  )$$,
  '23514',
  'PARTY_NOT_SPLIT',
  'an already repaired party cannot be moved again through the correction command'
);

select * from finish();
rollback;
