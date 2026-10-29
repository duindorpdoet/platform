// All fixture writes and initial materialization roll back. Never run remotely.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {sql, requireLocalTogetherDatabase} from './together-fixtures.mjs';
requireLocalTogetherDatabase();
const groupCount=Number(process.env.BOARD_BENCH_GROUPS??18);
const portalCount=Number(process.env.BOARD_BENCH_PORTALS??20);
assert.ok(Number.isInteger(groupCount)&&groupCount>=1&&groupCount<=100);
assert.ok(Number.isInteger(portalCount)&&portalCount>=1&&portalCount<=30);
const historicalReference=process.env.BOARD_BENCH_REFERENCE==='true';
const physicalReference=process.env.BOARD_BENCH_PHYSICAL_REFERENCE==='true';
assert.ok(!(historicalReference&&physicalReference),'Choose either historical or current-policy physical reference, not both');
let reference='';
if(historicalReference) {
 for(const [file,name] of [
  ['supabase/migrations/20261025090400_canonical_visits_and_occupancy.sql','app_private.portal_interval_available'],
  ['supabase/migrations/20261029021051_group_completion_target.sql','app_private.live_planboard_warnings'],
  ['supabase/migrations/20261026045351_keep_unavailable_route_portals_visible.sql','api.admin_live_planboard_snapshot_before_worlds'],
 ]) {
  const pattern=new RegExp('create(?: or replace)? function '+name.replaceAll('.','\\.')+'\\([\\s\\S]+?\\$\\$;','i');
  const match=readFileSync(file,'utf8').match(pattern);assert.ok(match,`Missing baseline ${name}`);reference+=match[0]+'\n';
 }
}
if(physicalReference) {
 // Restore only the pre-batching physical warning body under its current private
 // name. The canonical wrapper, windows, capacities and all other code stay current.
 const name='app_private.live_planboard_warnings_from_visits';
 const pattern=new RegExp('create(?: or replace)? function '+name.replaceAll('.','\\.')+'\\([\\s\\S]+?\\$\\$;','i');
 const match=readFileSync('supabase/migrations/20261029171520_shared_physical_arrival_validation.sql','utf8').match(pattern);
 assert.ok(match,'Missing pre-batching physical warning reference');
 reference=match[0].replace(name,'app_private.live_planboard_warnings_before_canonical_routes')+'\n';
}
// A physical-capacity benchmark needs actual assigned participants, not empty groups.
const partyHelper=readFileSync('scripts/acceptance/fixtures/together-party.sql','utf8');
const output=sql(`begin;
${reference}
${partyHelper}
set local statement_timeout='20s';
set local jit=off;
set local track_functions='all';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table bench_event as select id from app_private.events where slug='duindorp-halloween-2026';
update app_private.walking_groups set retired_at=clock_timestamp() where event_id=(select id from bench_event);
create temp table bench_groups(id uuid,n integer);
insert into bench_groups select md5('local-board-benchmark-'||n)::uuid,n from generate_series(1,${groupCount}) n;
insert into app_private.walking_groups(id,event_id,code,status,desired_ordinary_visits)
select b.id,e.id,'B'||lpad(b.n::text,3,'0'),'draft',${portalCount} from bench_groups b cross join bench_event e;
create temp table bench_parties as select b.id group_id,pg_temp.fixture_party(1,1) party_id from bench_groups b;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
select p.group_id,m.registration_id,1 from bench_parties p
join app_private.together_memberships m on m.party_id=p.party_id and m.left_at is null;
do $$ begin
 if (select count(*) from bench_groups b join app_private.group_registrations a on a.group_id=b.id and a.superseded_at is null join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active')<>${groupCount}
 or exists(select b.id from bench_groups b left join app_private.group_registrations a on a.group_id=b.id and a.superseded_at is null left join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' group by b.id having count(c.child_id)<>1)
 then raise exception 'NONEMPTY_BENCHMARK_FIXTURE_INVALID';end if;
end $$;
create temp table bench_portals as select id,row_number() over(order by system_number)::integer n
from app_private.portals where event_id=(select id from bench_event) and lifecycle_status='active' order by system_number limit ${portalCount};
insert into app_private.live_route_plans(group_id,event_id) select b.id,e.id from bench_groups b cross join bench_event e;
insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind)
select e.id,b.id,p.n,p.id,'2026-10-31T16:00Z'::timestamptz+make_interval(mins=>p.n*8+b.n*2),360,120,'ordinary'
from bench_groups b cross join bench_event e cross join bench_portals p;
create function pg_temp.measure_board() returns jsonb language plpgsql as $$
declare started timestamptz:=clock_timestamp(); board jsonb;
begin
 board:=api.admin_live_planboard_snapshot('duindorp-halloween-2026');
 return jsonb_build_object('milliseconds',round(extract(epoch from clock_timestamp()-started)*1000,2),
 'groups',jsonb_array_length(board->'groups'),'portals',(select count(*) from bench_portals),'visits',jsonb_array_length(board->'visits'),
 'warnings',jsonb_array_length(board->'warnings'),
 'assignedChildren',(select count(*) from bench_groups b join app_private.group_registrations a on a.group_id=b.id and a.superseded_at is null join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'),
 'warningCodes',(select coalesce(jsonb_object_agg(code,n),'{}') from(select coalesce(item->>'code','unknown') code,count(*) n from jsonb_array_elements(board->'warnings')item group by 1)t),
 'payloadBytes',octet_length(board::text),'inputHash',board->>'inputHash');
exception when query_canceled then return jsonb_build_object('timedOut',true,'milliseconds',round(extract(epoch from clock_timestamp()-started)*1000,2));
end $$;
select 'BENCH '||pg_temp.measure_board()::text;
select 'BENCH '||pg_temp.measure_board()::text;
select 'BENCH '||pg_temp.measure_board()::text;
select 'PROFILE '||coalesce(jsonb_agg(p),'[]')::text from
 (select funcname,calls,round(total_time::numeric,2) total_ms,round(self_time::numeric,2) self_ms
 from pg_stat_xact_user_functions order by self_time desc limit 15) p;
rollback;`);
const measurements=output.split('\n').filter(line=>line.startsWith('BENCH ')).map(line=>JSON.parse(line.slice(6)));
assert.equal(measurements.length,3);
const profile=output.split('\n').find(line=>line.startsWith('PROFILE '));
console.log(JSON.stringify({synthetic:true,rolledBack:true,reference:physicalReference?'prebatch-physical':historicalReference?'historical':'current',requestedGroups:groupCount,requestedPortals:portalCount,measurements,profile:profile?JSON.parse(profile.slice(8)):[]}));
if(process.env.BOARD_BENCH_REQUIRE_FAST==='true') {
 for(const m of measurements){assert.equal(m.timedOut,undefined);assert.equal(m.groups,groupCount);assert.equal(m.portals,portalCount);assert.equal(m.visits,groupCount*portalCount);assert.equal(m.assignedChildren,groupCount);assert.ok(m.milliseconds<8000,`Snapshot took ${m.milliseconds}ms`);}
 assert.equal(new Set(measurements.map(m=>m.inputHash)).size,1,'reads must not mutate intentions or hashes');
}
