import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';

/** Only route/arrival regression scenarios use this synthetic past appointment.
 * Privacy and OPS tests exercise their own real start-time publication boundary. */
export function prepareStartedLegacyFixtures() {
  requireLocalTogetherDatabase();
  const missing=Number(sql(`select count(*) from app_private.walking_groups g where g.route_mode='legacy' and exists(select 1 from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) and not exists(select 1 from app_private.finale_publication_commitments commitment where commitment.publication_id=(select p.id from app_private.group_start_publications p where p.group_id=g.id order by publication_order desc limit 1))`));
  if(!missing)return;
  assert.equal(sql('select count(*) from app_private.group_runs'),'0','create isolated legacy appointments before any route has started');
  sql(readFileSync('supabase/tests/fixtures/legacy-start-available.inc','utf8'));
}
