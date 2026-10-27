import {defineConfig,devices} from '@playwright/test';
export default defineConfig({
 testDir:'./tests/e2e',testMatch:'account-app.spec.ts',workers:1,retries:0,timeout:60000,reporter:'list',outputDir:'test-results/account-app',
 use:{baseURL:'https://127.0.0.1:3443',ignoreHTTPSErrors:true,launchOptions:{args:['--ignore-certificate-errors']},trace:'retain-on-failure',screenshot:'only-on-failure'},
 webServer:{command:'node scripts/acceptance/poortenboek-server.mjs',url:'https://127.0.0.1:3443/inloggen',ignoreHTTPSErrors:true,timeout:45000},
 projects:[{name:'account-desktop',use:{...devices['Desktop Chrome'],viewport:{width:1440,height:1000}}},{name:'account-mobile',use:{...devices['Pixel 7'],viewport:{width:360,height:800},reducedMotion:'reduce'}}],
});
