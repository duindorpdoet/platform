import {readFileSync} from 'node:fs';
import {requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';

/** Only route/arrival regression scenarios use this synthetic past appointment.
 * Privacy and OPS tests exercise their own real start-time publication boundary. */
export function prepareStartedLegacyFixtures() {
  requireLocalTogetherDatabase();
  sql(readFileSync('supabase/tests/fixtures/legacy-start-available.inc','utf8'));
}
