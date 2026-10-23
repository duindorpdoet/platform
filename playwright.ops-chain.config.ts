import {defineConfig,devices} from '@playwright/test';
export default defineConfig({
 testDir:'./tests/e2e',testMatch:'ops-large-group.spec.ts',workers:1,retries:0,timeout:60_000,reporter:'list',outputDir:'test-results/ops-chain',
 use:{...devices['Desktop Chrome'],baseURL:'https://127.0.0.1:3443',viewport:{width:390,height:844},ignoreHTTPSErrors:true,launchOptions:{args:['--ignore-certificate-errors']},trace:'retain-on-failure',screenshot:'only-on-failure'},
 webServer:{command:'node scripts/acceptance/poortenboek-server.mjs',url:'https://127.0.0.1:3443/poortenboek/inloggen',ignoreHTTPSErrors:true,timeout:45_000},
});
