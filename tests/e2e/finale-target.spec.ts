import { test, expect } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import { createTogetherFixtures, requireLocalTogetherDatabase, sql } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";
const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
test("a synthetic late group sees and saves a complete, honestly explained overrun proposal", async ({ page, context }) => {
  test.skip(!url || !key, "Requires isolated local Auth and database fixtures");
  test.setTimeout(90_000);
  requireLocalTogetherDatabase();
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(login.error).toBeNull(); await prepareFixtureGuidance(client);
  // Retain every seed family and immutable publication, but retire unrelated
  // appointments through the same reviewed reset used by the organization UI.
  // Its 23 seeded children otherwise already exceed this scenario's hard 20.
  // Repeating this setup also retires this test's own prior saved bookings.
  const preserved = () => sql(`select jsonb_build_array(
    (select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),
    (select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p),
    (select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p))`);
  const beforeReset = preserved();
  const impact = await client.schema("api").rpc("admin_group_operations_preview", { _event_slug: "duindorp-halloween-2026" });
  expect(impact.error).toBeNull();
  const reset = await client.schema("api").rpc("admin_group_operations_apply", { _event_slug: "duindorp-halloween-2026", _action: "reset",
    _input_hash: impact.data.inputHash, _payload: { confirmation: "ALLE GROEPEN TERUGZETTEN" }, _idempotency_key: randomUUID() });
  expect(reset.error).toBeNull(); expect(preserved()).toBe(beforeReset);
  sql(`update app_private.start_points set active=false where id='20000000-0000-0000-0000-000000000001' or name like 'Synthetic start %'`);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: "http://127.0.0.1:3100", sameSite: "Lax" as const })));
  const registrations = createTogetherFixtures(6, 1, 1).map(p => p.members[0].id);
  sql(`update app_private.event_route_settings set first_start_at='2026-10-31T17:00:00+01',global_ordinary_stop_at='2026-10-31T20:30:00+01',
    final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T19:00:00+01',finale_last_arrival_at='2026-10-31T21:25:00+01',finale_closes_at='2026-10-31T21:40:00+01',
    finale_show_seconds=600,finale_turnover_seconds=120,finale_planning_transfer_seconds=900,finale_max_concurrent_groups=1,finale_max_concurrent_children=20,finale_available=true,planner_mode='dynamic'
    where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
    update app_private.portal_windows set opens_at='2026-10-31T19:00:00+01',closes_at='2026-10-31T22:00:00+01',max_concurrent_groups=1,max_children_per_visit=20,max_children_total=20 where portal_id='12000000-0000-0000-0000-000000000030';
    create temporary table target_fixture(gid uuid,slot uuid,n integer);
    do $$declare e uuid:=(select id from app_private.events where slug='duindorp-halloween-2026');g uuid;p uuid;s uuid;ids uuid[]:=array[${registrations.map(id => `'${id}'`).join(",")}]::uuid[];start_at timestamptz;begin
    for n in 1..6 loop
      start_at:=case when n=6 then '2026-10-31T18:40:00+01'::timestamptz else '2026-10-31T17:00:00+01'::timestamptz end;
      insert into app_private.walking_groups(event_id,code,status,route_mode) values(e,'SYNTHETIC-'||n,'draft','dynamic') returning id into g;
      insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(g,ids[n],1);
      insert into app_private.start_points(event_id,name,private_address,latitude,longitude,available_from,available_until,max_gathering_groups,max_gathering_children,active)
      values(e,'Synthetic start '||n,'FICTIEF TESTADRES',52.1,4.27,start_at,start_at+interval '9 minutes',1,20,true) returning id into p;
      insert into app_private.start_slots(event_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,start_point_id)
      values(e,'Synthetic','Synthetic','FICTIEF TESTADRES',52.1,4.27,now(),start_at,1,20,p) returning id into s;
      insert into target_fixture values(g,s,n);
    end loop;
    update app_private.registrations set preferred_start_at='2026-10-31T18:30:00+01',desired_end_at='2026-10-31T21:00:00+01' where id=ids[6];
    end $$;
    begin;select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
    select api.admin_startregie_confirm_point('duindorp-halloween-2026',p.id,p.version) from app_private.start_points p where p.name like 'Synthetic start %';
    select api.admin_save_group_schedule(gid,slot,'2026-10-31T19:00:00+01','2026-10-31T19:54:00+01'::timestamptz+(n-1)*interval '12 minutes',null,'neutral','Synthetische bezette finaleplek voor browserregressie') from target_fixture where n<6;
    update app_private.group_schedule_revisions s set confirmed_at=clock_timestamp() from target_fixture f where f.gid=s.group_id and f.n<6;
    commit;`);
  const mails = sql("select count(*) from app_private.email_outbox");
  await page.goto("/admin"); await selectOrganizationSection(page, "Startregie");
  await page.getByRole("button", { name: "Groepen automatisch over startpunten verdelen", exact: true }).click();
  const proposal = page.getByRole("region", { name: "Bestaande groepen automatisch plannen" }).locator(".proposal-row");
  try { await expect(proposal).toHaveCount(1); }
  catch (error) { console.error("Synthetic finale planning notice:", await page.getByRole("status").allTextContents()); throw error; }
  for (const text of ["Startvoorkeur 18:30", "startmatch", "Gewenst klaar 21:00", "verwacht klaar 21:04", "4 minuten uitloop", "gewone poorten tot 20:30", "finale-aankomst 20:54", "fysieke bezetting tot 21:06", "geen bezoektijd"]) await expect(proposal).toContainText(text);
  for (const width of [1440, 390]) { await page.setViewportSize({ width, height: 1000 }); await assertReadableLayout(page); await proposal.scrollIntoViewIfNeeded(); await page.screenshot({ path: test.info().outputPath(`proposal-${width}.png`) }); }
  await page.getByRole("button", { name: "Conceptslotverdeling opslaan", exact: true }).click();
  await expect(proposal).toHaveCount(0);
  const saved = sql(`select jsonb_build_object('completion',s.input_snapshot->>'expectedCompletionAt','state',s.state) from app_private.group_schedule_revisions s join app_private.group_registrations a on a.group_id=s.group_id and a.superseded_at is null where a.registration_id='${registrations[5]}'`);
  expect(new Date(JSON.parse(saved).completion).toISOString()).toBe("2026-10-31T20:04:00.000Z");
  expect(JSON.parse(saved).state).toBe("draft");
  expect(sql("select count(*) from app_private.email_outbox")).toBe(mails);
});
