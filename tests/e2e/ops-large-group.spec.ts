import {test,expect} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {readFileSync,mkdirSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {requireLocalTogetherDatabase,sql} from '../../scripts/acceptance/together-fixtures.mjs';
import {prepareFixtureGuidance} from './helpers/guidance';
import {assertReadableLayout} from './helpers/layout';

test('45 children retain their real mobile roster, individual book and downloadable personal PDF',async({page,context})=>{
 requireLocalTogetherDatabase();
 // Reuse the independently passing real-command chain as a synthetic local fixture.
 // This suite gets its own reset before running; it never calls a remote database.
 const fixture=readFileSync('supabase/tests/068_large_group_full_journey.sql','utf8');
 const output=sql(fixture.replace('rollback;',`select jsonb_build_object('groupId',group_id,'childId',(select c.child_id from app_private.registration_children c where c.registration_id=large_chain.registration_id order by c.child_id limit 1)) from large_chain; commit;`));
 expect(output).not.toMatch(/not ok \d/);const line=output.split('\n').find(value=>value.startsWith('{')&&value.includes('groupId'));expect(line).toBeTruthy();const ids=JSON.parse(line!) as {groupId:string;childId:string};
 sql(`select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',false);select api.admin_assign_group_leader('${ids.groupId}','b0000000-0000-0000-0000-000000000001',(select version from app_private.walking_groups where id='${ids.groupId}'),'Afzonderlijke mobiele testleider met alleen deze grote groep');`);
 const client=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});
 const result=await client.auth.signInWithPassword({email:'parent-b@example.invalid',password:'local-test-only'});expect(result.error).toBeNull();await prepareFixtureGuidance(client);
 const name=`sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(result.data.session)).toString('base64url')}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:'https://127.0.0.1:3443',sameSite:'Lax' as const,secure:true})));
 const snapshot=await client.schema('api').rpc('group_snapshot',{_group_id:ids.groupId});expect(snapshot.error).toBeNull();expect(snapshot.data.run.participants).toHaveLength(45);
 await page.goto('/mijn-groep');await expect(page.locator('main')).toContainText('Ketenproefkind 45');await assertReadableLayout(page);mkdirSync('docs/ops/screenshots',{recursive:true});await page.screenshot({path:'docs/ops/screenshots/large-roster-390.png',fullPage:true});
 const token=randomBytes(32).toString('base64url'),hash=createHash('sha256').update(token).digest('hex');
 sql(`update app_private.poortenboek_sessions set token_hash='${hash}' where code_id=(select id from app_private.poortenboek_codes where child_id='${ids.childId}'); do $$begin for step in 1..8 loop perform api.poortenboek_child_action('${hash}','tutorial',jsonb_build_object('version',1,'step',step));end loop;perform api.poortenboek_child_action('${hash}','tutorial','{"version":1,"step":8,"completed":true}');end $$;`);
 await context.clearCookies();await context.addCookies([{name:'__Host-poortenboek-session',value:token,url:'https://127.0.0.1:3443',httpOnly:true,secure:true,sameSite:'Lax'}]);
 await page.goto('/poortenboek/boek');await page.getByRole('button',{name:'Dit is mijn boek',exact:true}).click();await page.getByRole('button',{name:'Open mijn boek',exact:true}).click();await page.goto('/poortenboek/boek');await expect(page.getByRole('button',{name:'Download mijn bewaarkaart'})).toBeVisible();await assertReadableLayout(page);
 const book=await page.request.get('/api/poortenboek/snapshot');expect(book.status()).toBe(200);const data=await book.json();expect(data.journey.seals).toHaveLength(1);expect(data.firstName).toMatch(/^Ketenproefkind /);
 const downloadPromise=page.waitForEvent('download');await page.getByRole('button',{name:'Download mijn bewaarkaart'}).click();const download=await downloadPromise;await download.saveAs('docs/ops/screenshots/large-group-personal-book.pdf');
 const pdf=readFileSync('docs/ops/screenshots/large-group-personal-book.pdf').toString('latin1');expect(pdf.startsWith('%PDF-1.')).toBe(true);expect(pdf).not.toContain('TESTADRES');expect(pdf).not.toContain(token);expect(pdf).toContain('(1)');
 await page.screenshot({path:'docs/ops/screenshots/large-book-390.png',fullPage:true});await page.setViewportSize({width:360,height:800});await assertReadableLayout(page);await page.screenshot({path:'docs/ops/screenshots/large-book-360.png',fullPage:true});
});
