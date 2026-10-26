import {defineConfig,devices} from '@playwright/test';
export default defineConfig({
 testDir:'./tests/e2e',testMatch:'live-planboard.spec.ts',workers:1,retries:0,timeout:90000,reporter:'list',outputDir:'test-results/live-planboard',
 use:{...devices['Desktop Chrome'],baseURL:'https://127.0.0.1:3443',viewport:{width:1440,height:1000},ignoreHTTPSErrors:true,launchOptions:{args:['--ignore-certificate-errors']},trace:'retain-on-failure',screenshot:'only-on-failure'},
 webServer:{command:'node scripts/acceptance/poortenboek-server.mjs',url:'https://127.0.0.1:3443/poortenboek/inloggen',ignoreHTTPSErrors:true,timeout:45000},
});
