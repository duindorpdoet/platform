#!/usr/bin/env python3
"""Read-only, private row fingerprints; credentials come exclusively from libpq.

Use PGSERVICE/PGSERVICEFILE with an operator-provided service entry. No DSN,
password, row contents or IDs are accepted as command arguments or printed.
This is an inventory/comparison tool, not a backup or a migration runner.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess


def query(sql):
    result = subprocess.run(
        ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
        input=sql, text=True, capture_output=True, check=False,
    )
    if result.returncode:
        # Driver messages can contain connection details. Keep them private.
        raise RuntimeError('Private inventory failed; inspect the database connection and permissions locally.')
    return result.stdout


def identifier(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    if not os.environ.get('PGSERVICE'):
        parser.error('Set PGSERVICE to an existing private libpq service; never supply a password on the command line.')
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.is_relative_to(repo) or output.exists():
        parser.error('Choose a new private output file outside the repository.')
    baseline = json.loads(args.baseline.read_text()) if args.baseline else None
    catalog = json.loads(query("""
      begin isolation level repeatable read read only;
      set local statement_timeout='5min'; set local lock_timeout='3s';
      select coalesce(jsonb_agg(jsonb_build_object(
        'key',n.nspname||'.'||c.relname,'schema',n.nspname,'table',c.relname,
        'rls',c.relrowsecurity,'columns',(select jsonb_agg(a.attname order by a.attnum)
          from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)
      ) order by n.nspname,c.relname),'[]')
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname in ('app_private','auth','storage','supabase_migrations') and c.relkind in ('r','p');
      commit;
    """))
    previous = {t['key']: t for t in baseline['tables']} if baseline else {}
    current_keys = {t['key'] for t in catalog}
    if set(previous) - current_keys:
        raise RuntimeError('A baseline table is missing; rollout blocked.')
    commands = ["begin isolation level repeatable read read only;",
                "set local statement_timeout='5min'; set local lock_timeout='3s';"]
    for table in catalog:
        columns = previous.get(table['key'], table)['columns']
        if not set(columns) <= set(table['columns']):
            raise RuntimeError('A baseline column is missing; rollout blocked.')
        table['newColumns'] = sorted(set(table['columns']) - set(columns))
        table['columns'] = columns
        projection = ','.join('t.' + identifier(c) for c in columns)
        qualified = identifier(table['schema']) + '.' + identifier(table['table'])
        # Hash complete projected rows, then a sorted multiset of those hashes.
        # Relations and stable IDs remain bound to the same row. New columns do
        # not create false differences when comparing an expanded schema.
        commands.append(f"""select jsonb_build_object('key',{literal(table['key'])},
          'rows',count(*),'sha256',encode(sha256(convert_to(
            coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex'))
          from (select encode(sha256(convert_to(to_jsonb(row({projection}))::text,'UTF8')),'hex') h
            from {qualified} t) fingerprints;""")
    commands.append('commit;')
    fingerprints = {r['key']: r for r in map(json.loads, query('\n'.join(commands)).splitlines())}
    for table in catalog:
        table.update(fingerprints[table['key']])
    changed = [t['key'] for t in catalog if t['key'] in previous and
               any(t[k] != previous[t['key']][k] for k in ('rows', 'sha256'))]
    report = {
        'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'app_private/auth/storage metadata and rows; excludes storage object bytes and provider configuration',
        'consistentDataSnapshot': True,
        'baselineComparison': {'changedExistingTables': changed,
                               'newTables': sorted(current_keys - set(previous))} if baseline else None,
        'tables': catalog,
    }
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    print(json.dumps({'tables': len(catalog), 'changedExistingTables': len(changed),
                      'status': 'blocked' if changed else 'recorded'}))
    return 2 if changed else 0


if __name__ == '__main__':
    raise SystemExit(main())
