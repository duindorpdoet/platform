// All fixture writes and initial materialization roll back. Never run remotely.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {sql, requireLocalTogetherDatabase} from './together-fixtures.mjs';
requireLocalTogetherDatabase();
const groupCount=Number(process.env.BOARD_BENCH_GROUPS??18);
const portalCount=Number(process.env.BOARD_BENCH_PORTALS??20);
assert.ok(Number.isInteger(groupCount)&&groupCount>=1&&groupCount<=100);
assert.ok(Number.isInteger(portalCount)&&portalCount>=1&&portalCount<=30);
let reference='';
if(process.env.BOARD_BENCH_REFERENCE==='true') {
 for(const [file,name] of [
  ['supabase/migrations/20261025090400_canonical_visits_and_occupancy.sql','app_private.portal_interval_available'],
  ['supabase/migrations/20261029021051_group_completion_target.sql','app_private.live_planboard_warnings'],
  ['supabase/migrations/20261026045351_keep_unavailable_route_portals_visible.sql','api.admin_live_planboard_snapshot_before_worlds'],
 ]) {
  const pattern=new RegExp('create(?: or replace)? function '+name.replaceAll('.','\\.')+'\\([\\s\\S]+?\\$\\$;','i');
  const match=readFileSync(file,'utf8').match(pattern);assert.ok(match,`Missing baseline ${name}`);reference+=match[0]+'\n';
 }
}
const output=sql(`begin;
${reference}
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
 'warnings',jsonb_array_length(board->'warnings'),'payloadBytes',octet_length(board::text),'inputHash',board->>'inputHash');
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
if(process.env.BOARD_BENCH_REQUIRE_FAST==='true') {
 for(const m of measurements){assert.equal(m.timedOut,undefined);assert.ok(m.milliseconds<8000,`Snapshot took ${m.milliseconds}ms`);}
 assert.equal(new Set(measurements.map(m=>m.inputHash)).size,1,'reads must not mutate intentions or hashes');
}
const profile=output.split('\n').find(line=>line.startsWith('PROFILE '));
console.log(JSON.stringify({synthetic:true,rolledBack:true,requestedGroups:groupCount,requestedPortals:portalCount,measurements,profile:profile?JSON.parse(profile.slice(8)):[]}));
