import { expect, type Page } from '@playwright/test';
import type { SupabaseClient } from '@supabase/supabase-js';

/** Establish completed onboarding for unrelated local regression scenarios.
 * These are real authorized RPCs, in order, for synthetic local accounts only.
 * Dedicated onboarding acceptance must exercise the visible first-run UI.
 */
export async function prepareFixtureGuidance(client: SupabaseClient) {
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
  if(!url||!['localhost','127.0.0.1'].includes(new URL(url).hostname))throw new Error('LOCAL_GUIDANCE_FIXTURES_ONLY');
  const initial=await client.schema('api').rpc('participant_guidance',{_event_slug:'duindorp-halloween-2026'});
  if(initial.error?.message==='NOT_AUTHORIZED')return; // No participant role yet.
  expect(initial.error).toBeNull();
  expect((await client.schema('api').rpc('participant_guidance',{_event_slug:'duindorp-halloween-2026',_action:'acknowledge'})).error).toBeNull();
  for(const role of (initial.data.roles as string[]).filter(role=>role==='parent'||role==='house')) {
    if(initial.data.completed?.[role]===1)continue;
    for(let index=0;index<=13;index++) {
      const result=await client.schema('api').rpc('participant_guidance',{_event_slug:'duindorp-halloween-2026',_action:'tutorial',_role:role,_payload:{version:1,index,completed:false,returnPath:'/omgeving'}});
      expect(result.error).toBeNull();
    }
    expect((await client.schema('api').rpc('participant_guidance',{_event_slug:'duindorp-halloween-2026',_action:'tutorial',_role:role,_payload:{version:1,index:13,completed:true,returnPath:'/omgeving'}})).error).toBeNull();
  }
}

export async function selectOrganizationSection(page: Page, name: string) {
  const aliases:Record<string,string>={Cockpit:'Overzicht',Samenloop:'Samenlopen',Live:'Livecockpit',Berichten:'Inbox',Messenger:'Inbox',Toegangen:'Beheerders',Deelnemersupdates:'Updates','Content & sponsors':'Website & sponsors','Avond live':'Livecockpit',Avondsimulatie:'Generale'};
  const label=aliases[name]??name;
  const groups: Record<string,string>={
    Inschrijvingen:'Deelnemers',Samenloop:'Deelnemers',Samenlopen:'Deelnemers',Groepsindeling:'Deelnemers',Betalingen:'Deelnemers',Poortenboek:'Deelnemers',
    Inbox:'Communicatie',Berichten:'Communicatie',Messenger:'Communicatie',Updates:'Communicatie',Praatkamer:'Communicatie',Redactiekamer:'Communicatie',Deelstudio:'Communicatie','Website & sponsors':'Communicatie',
    Cockpit:'Overzicht',Live:'De avond',Livecockpit:'De avond',Generale:'De avond',Bedankjes:'De avond','Gereed voor de avond':'De avond',
    Instellingen:'Beheer','Push & beveiliging':'Beheer',Beheerders:'Beheer',Toegangen:'Beheer',Imports:'Beheer',Statistieken:'Beheer',
  };
  const group=groups[label]??label;
  await expect(page.locator('.admin-appbar')).toBeVisible();
  const more=page.getByRole('button',{name:'Meer',exact:true}),menu=page.getByRole('button',{name:'Organisatienavigatie openen'});
  if(await more.isVisible())await more.click();else if(await menu.isVisible())await menu.click();
  const primary=page.locator('.modern-primary-nav').getByRole('button',{name:new RegExp('^'+group+'(?:\\s*\\d+)?$'),includeHidden:true});
  await primary.click();
  await expect(primary).toHaveClass(/active/);
  if(group!==label) {
    const secondary=page.locator('.modern-admin-subnav').getByRole('button',{name:label,exact:true});
    await secondary.click();
    await expect(secondary).toHaveClass(/active/);
  }
}
