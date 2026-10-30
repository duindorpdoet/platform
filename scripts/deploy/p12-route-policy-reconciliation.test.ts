import { describe,expect,it } from 'vitest';
import { JOINT_ROUTE_SETTINGS_MIGRATION,reconcileJointRouteSettingsInitialization } from './joint-route-settings-reconciliation.mjs';
import { P12_ROUTE_POLICY_MIGRATION,p12RoutePolicyQuery,reconcileP12RoutePolicy,jointRouteSettingsBeforeP12Policy,type P12RoutePolicySnapshot } from './p12-route-policy-reconciliation.mjs';
import { compareFingerprints,preservationQuery } from './redesign-backup.mjs';

const settingsTable='app_private.event_route_settings',portalsTable='app_private.portals',windowsTable='app_private.portal_windows';
const versions=[P12_ROUTE_POLICY_MIGRATION];
const at='2026-10-30T18:30:00.000001Z',close='2026-10-31T18:00:00Z';
const settings={event_id:'main',max_total_walking_seconds:3900,route_policy_version:1,version:10,
  updated_at:'2026-10-29T08:00:00Z',updated_by:'unchanged-admin',max_early_finish_seconds:1800,
  organizer_coverage_portal_ids:['p02','p12'],nested:{keep:['all','fields']}};
const portal={id:'p12',event_id:'main',system_code:'P-12',ordinary_hard_close:false,ordinary_end_grace_seconds:300,
  version:7,updated_at:'2026-10-29T09:00:00Z',updated_by:'same-admin',arrival_headway_seconds:300,accessibility_status:'unknown'};
const window={id:'window12',portal_id:'p12',opens_at:'2026-10-31T16:00:00Z',closes_at:'2026-10-31T18:10:00Z',
  visit_minutes:5,buffer_minutes:2,max_concurrent_groups:2};
const before=():P12RoutePolicySnapshot=>({capturedAt:'2026-10-30T18:30:00.000000Z',appliedMigrations:[JOINT_ROUTE_SETTINGS_MIGRATION],tablesExist:true,
  settings:[structuredClone(settings),{...structuredClone(settings),event_id:'other'}],
  portals:[structuredClone(portal),{...structuredClone(portal),id:'other-p12',event_id:'other'},
    {...structuredClone(portal),id:'p02',system_code:'P-02'}],
  windows:[structuredClone(window),{...structuredClone(window),id:'other-window',portal_id:'other-p12'}],
  targetEvents:[{event_id:'main',close_at:close}]});
const after=():P12RoutePolicySnapshot=>{
  const next=before();next.capturedAt='2026-10-30T18:30:00.000002Z';next.appliedMigrations.push(P12_ROUTE_POLICY_MIGRATION);
  next.settings[0]={...next.settings[0],max_total_walking_seconds:4500,route_policy_version:2};
  next.portals[0]={...next.portals[0],ordinary_hard_close:true,ordinary_end_grace_seconds:0,version:8,updated_at:at};
  next.windows[0]={...next.windows[0],closes_at:close};return next;
};
const reconcile=(next=after(),original=before(),expected=versions)=>reconcileP12RoutePolicy(original,next,expected);

describe('exact event-specific P12 closing and 75-minute walking reconciliation',()=>{
  it('accepts only the reviewed three row changes and retains all complete unrelated rows',()=>{
    expect(reconcile()).toEqual({failures:[],reconciledTables:[settingsTable,portalsTable,windowsTable],changedSettingsRows:1,changedPortalRows:1,changedWindowRows:1});
    const reordered=after();reordered.settings.reverse();reordered.portals.reverse();reordered.windows.reverse();
    expect(reconcile(reordered).failures).toEqual([]);
  });
  it('rejects missing, extra, duplicated or reassigned rows in each complete table',()=>{
    for(const name of ['settings','portals','windows'] as const)for(const mutation of ['remove','add','duplicate','reassign']) {
      const next=after(),rows=next[name] as Array<Record<string,unknown>>;
      if(mutation==='remove')rows.pop();
      if(mutation==='add')rows.push({...rows[0],[name==='settings'?'event_id':'id']:'unreviewed'});
      if(mutation==='duplicate')rows[1]={...rows[0]};
      if(mutation==='reassign')rows[1]={...rows[1],[name==='settings'?'event_id':'id']:'reassigned'};
      expect(reconcile(next).failures.length,`${name}:${mutation}`).toBeGreaterThan(0);
    }
  });
  it('rejects settings budget/version tampering and every old-field mutation',()=>{
    for(const change of [{max_total_walking_seconds:4501},{route_policy_version:1},{route_policy_version:3},{version:11},
      {updated_at:at},{updated_by:'other-admin'},{max_early_finish_seconds:0},{organizer_coverage_portal_ids:['p12','p02']},
      {nested:{keep:['changed']}},{extra_field:true}]) {
      const next=after();Object.assign(next.settings[0],change);expect(reconcile(next).failures).toContain(settingsTable);
    }
    const unexpected=before();unexpected.settings[0].max_total_walking_seconds=4000;
    expect(reconcile(after(),unexpected).failures).toContain(settingsTable);
    const unrelated=after();unrelated.settings[1].max_total_walking_seconds=4500;
    expect(reconcile(unrelated).failures).toContain(settingsTable);
  });
  it('rejects portal status, accessibility, arrival spacing, actor or unrelated portal mutations',()=>{
    for(const change of [{ordinary_hard_close:false},{ordinary_end_grace_seconds:1},{version:7},{version:9},
      {arrival_headway_seconds:0},{accessibility_status:'step_free'},{updated_by:'other-admin'},{extra:true}]) {
      const next=after();Object.assign(next.portals[0],change);expect(reconcile(next).failures).toContain(portalsTable);
    }
    for(const index of [1,2]) {
      const next=after();next.portals[index].ordinary_hard_close=true;expect(reconcile(next).failures).toContain(portalsTable);
    }
  });
  it('allows only raw19:10→19:00 and no window duration/capacity/opening/buffer changes',()=>{
    for(const change of [{closes_at:'2026-10-31T18:01:00Z'},{opens_at:'2026-10-31T15:00:00Z'},
      {visit_minutes:6},{buffer_minutes:0},{max_concurrent_groups:3},{updated_at:at}]) {
      const next=after();Object.assign(next.windows[0],change);expect(reconcile(next).failures).toContain(windowsTable);
    }
    const unexpected=before();unexpected.windows[0].closes_at='2026-10-31T18:15:00Z';
    expect(reconcile(after(),unexpected).failures).toContain(windowsTable);
    const unrelated=after();unrelated.windows[1].closes_at=close;expect(reconcile(unrelated).failures).toContain(windowsTable);
  });
  it('requires one migration transaction timestamp within the exact microsecond capture window',()=>{
    for(const changedAt of ['2026-10-30T18:29:59.999999Z','2026-10-30T18:30:00.000003Z','invalid']) {
      const next=after();next.portals[0].updated_at=changedAt;expect(reconcile(next).failures).toContain(portalsTable);
    }
    const original=before(),inconsistent=after();
    original.portals.push({...original.portals[0],id:'second-p12'});
    inconsistent.portals.push({...inconsistent.portals[0],id:'second-p12',updated_at:'2026-10-30T18:30:00.000002Z'});
    expect(reconcile(inconsistent,original).failures).toContain(portalsTable);
    const reversed=after();reversed.capturedAt='2026-10-30T18:29:00Z';expect(reconcile(reversed).failures.length).toBeGreaterThan(0);
  });
  it('requires the pending reviewed migration and rejects any delta after installation',()=>{
    expect(reconcile(after(),before(),[]).failures.length).toBeGreaterThan(0);
    const installed=before();installed.appliedMigrations.push(P12_ROUTE_POLICY_MIGRATION);
    expect(reconcile(after(),installed).failures.length).toBeGreaterThan(0);
    expect(reconcile(after(),after()).reconciledTables).toEqual([]);
    const tampered=after();tampered.settings[0].max_total_walking_seconds=4501;
    expect(reconcile(tampered,after()).failures).toContain(settingsTable);
  });
  it('preserves already-correct policy rows without an extra version or timestamp change',()=>{
    const original=before();Object.assign(original.settings[0],{max_total_walking_seconds:4500,route_policy_version:2});
    Object.assign(original.portals[0],{ordinary_hard_close:true,ordinary_end_grace_seconds:0});original.windows[0].closes_at=close;
    expect(reconcile(structuredClone(original),original)).toEqual({failures:[],reconciledTables:[],changedSettingsRows:0,changedPortalRows:0,changedWindowRows:0});
    const unnecessary=structuredClone(original);unnecessary.settings[0].updated_at=at;
    expect(reconcile(unnecessary,original).failures).toContain(settingsTable);
  });
  it('fails closed on missing metadata, invalid derivations and absent tables',()=>{
    expect(reconcileP12RoutePolicy(undefined,after(),versions).failures.length).toBeGreaterThan(0);
    for(const changes of [{tablesExist:false},{appliedMigrations:undefined},{appliedMigrations:['duplicate','duplicate']},
      {targetEvents:[{event_id:'main',close_at:'invalid'}]},{targetEvents:[before().targetEvents[0],before().targetEvents[0]]}])
      expect(reconcile(after(),{...before(),...changes} as P12RoutePolicySnapshot).failures.length).toBeGreaterThan(0);
  });
  it('normalizes only a fully verified overlay before the existing strict settings guard',()=>{
    const previous=before(),next=after();
    const initialization=(rows:typeof previous.settings)=>({capturedAt:at,migrationApplied:true,tableExists:true,rows,expectedTargets:[]});
    const normalized=jointRouteSettingsBeforeP12Policy(previous,next,versions,initialization(next.settings));
    expect(normalized?.rows).toEqual(previous.settings);
    expect(reconcileJointRouteSettingsInitialization(initialization(previous.settings),normalized,versions).failures).toEqual([]);
    const altered=after();altered.settings[0].updated_by='changed';
    expect(jointRouteSettingsBeforeP12Policy(previous,altered,versions,initialization(altered.settings))).toBeUndefined();
    expect(jointRouteSettingsBeforeP12Policy(previous,next,versions,initialization(previous.settings))).toBeUndefined();
  });
  it('composes with the separately verified v3 four-column initialization without waiving old data',()=>{
    const previous=before();previous.appliedMigrations=[];
    for(const row of previous.settings)for(const column of ['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version'])delete row[column];
    const next=after(),expected=[JOINT_ROUTE_SETTINGS_MIGRATION,...versions];
    const initBefore={capturedAt:previous.capturedAt,migrationApplied:false,tableExists:true,rows:previous.settings,
      expectedTargets:[{event_id:'main',organizer_coverage_portal_ids:['p02','p12']},{event_id:'other',organizer_coverage_portal_ids:['p02','p12']}]};
    const initAfter={...initBefore,migrationApplied:true,rows:next.settings};
    const normalized=jointRouteSettingsBeforeP12Policy(previous,next,expected,initAfter);
    expect(reconcileP12RoutePolicy(previous,next,expected).failures).toEqual([]);
    expect(reconcileJointRouteSettingsInitialization(initBefore,normalized,expected).failures).toEqual([]);
    next.settings[0].organizer_coverage_portal_ids=['p12','p02'];
    const wrongDefaults=jointRouteSettingsBeforeP12Policy(previous,next,expected,{...initAfter,rows:next.settings});
    expect(reconcileJointRouteSettingsInitialization(initBefore,wrongDefaults,expected).failures).toEqual([settingsTable]);
    next.settings[0].version=11;expect(reconcileP12RoutePolicy(previous,next,expected).failures).toContain(settingsTable);
  });
  it('captures all full rows and server-derived event-local closing in the same preservation statement',()=>{
    const catalog=['event_route_settings','portals','portal_windows','events'].map(name=>({schema:'app_private',name,columns:['id']}));
    const query=p12RoutePolicyQuery(catalog);
    for(const fragment of ["e.slug='duindorp-halloween-2026'","(e.local_date+time '19:00') at time zone e.timezone",'to_jsonb(r)'])expect(query).toContain(fragment);
    expect(query).not.toMatch(/\b(insert|update|delete|alter)\b/i);
    expect(p12RoutePolicyQuery([])).not.toContain('from app_private.portals');
    const atomic=preservationQuery(catalog);expect(atomic).toContain("'p12RoutePolicy',(select p12_route_policy from p12_policy)");
    expect(atomic).toContain("'rows',(select jsonb_agg(fingerprint)");
    const checked=reconcile();
    const unchanged=[{table:'app_private.live_route_visits',rows:287,sha256:'original'}];
    expect(compareFingerprints(unchanged,[{...unchanged[0],sha256:'changed'}]).filter(table=>!checked.reconciledTables.includes(table))).toEqual(['app_private.live_route_visits']);
  });
});
