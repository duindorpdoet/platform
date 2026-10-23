import { chromium } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const base=process.env.APP_URL||'http://127.0.0.1:3100';
if(new URL(base).hostname!=='127.0.0.1'&&new URL(base).hostname!=='localhost')throw new Error('Use this read-only screenshot harness only on the local QA app.');
const out=path.resolve('docs/redesign/validation');await mkdir(out,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH}:{}),args:['--no-sandbox']});
const results=[];
for(const width of [1363,360,390,430,768]){
 const page=await browser.newPage({viewport:{width,height:width===1363?900:width===768?1024:844},deviceScaleFactor:1,reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(base,{waitUntil:'domcontentloaded'});await page.evaluate(()=>document.fonts.ready);await page.locator('.public-hero-art img').evaluate(img=>img.decode());
 const metrics=await page.evaluate(()=>({width:innerWidth,overflow:document.documentElement.scrollWidth>innerWidth,header:document.querySelector('header')?.getBoundingClientRect().toJSON(),hero:document.querySelector('.public-hero')?.getBoundingClientRect().toJSON(),heading:document.querySelector('h1')?.getBoundingClientRect().toJSON(),font:getComputedStyle(document.querySelector('h1')).fontFamily,prototypeOffset:getComputedStyle(document.documentElement).getPropertyValue('--prototype-bar-height')}));
 if(metrics.overflow)throw new Error('Horizontal overflow at '+width);
 if(width===1363){const cdp=await page.context().newCDPSession(page);await cdp.send('DOM.enable');await cdp.send('CSS.enable');const dom=await cdp.send('DOM.getDocument');const node=await cdp.send('DOM.querySelector',{nodeId:dom.root.nodeId,selector:'.public-hero h1'});metrics.renderedFonts=await cdp.send('CSS.getPlatformFontsForNode',{nodeId:node.nodeId});}
 await page.screenshot({path:path.join(out,`home-${width}.png`)});
 if(width===390){await page.getByRole('button',{name:'Menu openen',exact:true}).click();await page.screenshot({path:path.join(out,'public-mobile-menu-390.png')});await page.keyboard.press('Escape');}
 results.push({route:'/',...metrics,errors});
 await page.close();
}
const page=await browser.newPage({viewport:{width:1363,height:900},deviceScaleFactor:1,reducedMotion:'reduce'});
for(const route of ['/verhaal','/werelden','/kaart','/faq','/meelopen','/huis-aanmelden','/sponsoren','/contact','/nieuws','/ontdek','/deel-de-magie','/privacy','/voorwaarden','/toegankelijkheid']){
 await page.goto(base+route,{waitUntil:'domcontentloaded'});
 const info=await page.evaluate(()=>({title:document.querySelector('h1')?.textContent,overflow:document.documentElement.scrollWidth>innerWidth}));
 await page.screenshot({path:path.join(out,`public-${route.slice(1)}-1363.png`)});results.push({route,...info});
}
await browser.close();await writeFile(path.join(out,'public-browser-results.json'),JSON.stringify({capturedAt:new Date().toISOString(),environment:'local Next production build, staging public read-only configuration',results},null,2)+'\n');
console.log(JSON.stringify({screenshots:20,viewports:5,publicPages:15,errors:results.flatMap(r=>r.errors??[]),overflows:results.filter(r=>r.overflow).map(r=>r.route)}));
