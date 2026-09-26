-- Used only by guarded local acceptance scripts, never by a migration or seed.
create function pg_temp.fixture_party(_members integer default 1, _children integer default 1)
returns uuid language plpgsql as $$
declare p uuid := gen_random_uuid(); h uuid; r uuid; c uuid; e uuid := (select id from app_private.events where slug = 'duindorp-halloween-2026');
begin
  for i in 1.._members loop
    insert into app_private.households(label, primary_contact_user_id) values ('Cluster test ' || i, 'f0000000-0000-0000-0000-000000000001') returning id into h;
    insert into app_private.household_members(household_id,user_id,relation_role) values(h,'f0000000-0000-0000-0000-000000000001','owner');
    insert into app_private.registrations(event_id, household_id, status, reference, submitted_at)
      values(e, h, 'submitted', 'DPH-2026-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), now()) returning id into r;
    if i = 1 then insert into app_private.together_parties(id, event_id, public_label, creator_household_id, invite_token_hash, expires_at)
      values(p, e, 'Samenloop', h, extensions.gen_random_bytes(32), now() + interval '1 year'); end if;
    for j in 1.._children loop
      insert into app_private.children(household_id, first_name, age_at_event) values(h, 'Clusterkind ' || j, 8) returning id into c;
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents) values(e, r, c, 250);
    end loop;
    insert into app_private.together_memberships(party_id, registration_id) values(p, r);
  end loop;
  return p;
end;
$$;
