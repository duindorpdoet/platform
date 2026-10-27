import {defineConfig,devices} from '@playwright/test';
const baseline=process.env.GUIDANCE_BASELINE_DIR;
export default defineConfig({
 testDir:'./tests/e2e',testMatch:'guidance.spec.ts',workers:1,retries:0,timeout:90000,reporter:'list',outputDir:'test-results/guidance',
 use:{serviceWorkers:'block',...(process.env.GUIDANCE_BROWSER_WS?{connectOptions:{wsEndpoint:process.env.GUIDANCE_BROWSER_WS,exposeNetwork:'<loopback>'}}:{}),baseURL:'https://127.0.0.1:3443',ignoreHTTPSErrors:true,launchOptions:{args:['--ignore-certificate-errors']},trace:'retain-on-failure',screenshot:'only-on-failure'},
 webServer:{command:'node scripts/acceptance/poortenboek-server.mjs',...(baseline?{cwd:baseline}:{}),url:'https://127.0.0.1:3443/inloggen',ignoreHTTPSErrors:true,reuseExistingServer:process.env.GUIDANCE_EXTERNAL_SERVER==='true',timeout:60000},
 projects:[{name:'guidance-desktop',use:{...devices['Desktop Chrome'],viewport:{width:1440,height:1000}}},{name:'guidance-iphone',use:{...devices['iPhone 13'],launchOptions:{}}}],
});
