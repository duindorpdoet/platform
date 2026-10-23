# Portal management hotfix

Organization → Poorten → Poorten beheren now lists resident and manual portal records with edit and removal actions. Existing registration and active-portal rows also open the editor directly. The editor loads structured address fields, intensity, contact details, accessibility, notes, visit duration and buffer without replacing existing values with defaults.

The portal-only snapshot requires `portals_manage` or `event_admin` and exposes no group-planning data. Save and removal retain capability checks, event serialization and optimistic portal versions. Removal requires confirmation. An unused manual concept can be deleted; other portals are archived, closed and removed from active lists while applications, teams and historical references remain. Current start assignments, configured finale, held/active reservations and current route destinations block removal. Registration history reflects managed contact/address data and identifies archived records as closed.

Unrelated edits retain existing availability rows, IDs and unexposed total capacities. One existing window can be edited in place. Multiple windows remain intact; this editor rejects availability changes that would flatten them. Moving a marker continues to invalidate its verified walking connection.

The additive migration changes function definitions and privileges only. It performs no data backfill, deletion, reset or credential rotation, and is included in the reviewed encrypted-backup/isolated-restore release manifest.

Validation: full unit and pgTAP suites, SQL error-level lint, lint/typecheck/build/client-artifact scan, real Auth/API desktop and mobile browser edit/reload/cancel-removal/confirmed-removal flows, plus GitHub CI and staging/production backup and deployment gates. The browser fixture and SQL contracts are restricted to isolated synthetic local data. Actual production portal records are changed only by an authorized organization user through these controls.
