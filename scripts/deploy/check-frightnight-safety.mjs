import { management } from './redesign-preflight.mjs';
import { assertFrightnightRelease, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from './frightnight-release.mjs';

assertFrightnightRelease(process.env);
const rows = await management('/database/query', { read_only: true, query: FRIGHTNIGHT_SAFETY_SQL });
const safety = assertFrightnightSafety(rows[0]?.frightnight_safety, !process.argv.includes('--schema-only'));
console.log(JSON.stringify({frightnightSafety:'passed',tables:safety.tables,editionConfigured:Boolean(safety.edition),mailMode:'sink',legacyJobsPreserved:true,readOnly:true}));
