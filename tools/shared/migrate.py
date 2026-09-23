#!/usr/bin/env python3
"""Copy a stopped tenant database into shared schemas and verify every data row.

Requires matching PostgreSQL client/server major versions, a prepared shared
public extension schema, and admin DSNs in environment variables. Never changes
or drops the source database and never activates the new assignment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
from urllib.parse import urlsplit, urlunsplit, unquote, parse_qsl


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def database_url(dsn, name):
    parsed = urlsplit(dsn)
    if parsed.scheme not in ('postgres', 'postgresql') or not parsed.hostname:
        raise ValueError('PostgreSQL URL required in DSN environment variable')
    return urlunsplit(parsed._replace(path='/' + name))


def connection_env(dsn):
    parsed = urlsplit(dsn)
    env = dict(os.environ, PGDATABASE=unquote(parsed.path.lstrip('/')),
               PGHOST=parsed.hostname or '', PGPORT=str(parsed.port or 5432),
               PGUSER=unquote(parsed.username or ''), PGPASSWORD=unquote(parsed.password or ''),
               PGOPTIONS='-c timezone=UTC -c extra_float_digits=3')
    options = {'sslmode': 'PGSSLMODE', 'sslrootcert': 'PGSSLROOTCERT',
               'sslcert': 'PGSSLCERT', 'sslkey': 'PGSSLKEY', 'connect_timeout': 'PGCONNECT_TIMEOUT'}
    for key, value in parse_qsl(parsed.query):
        if key not in options:
            raise ValueError('unsupported PostgreSQL URL option: ' + key)
        env[options[key]] = value
    return env


def run(dsn, tool, *args, input=None):
    env = connection_env(dsn)
    # DSNs and database output are not printed on failure (they may include data).
    result = subprocess.run([tool, *args], input=input, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    if result.returncode:
        raise RuntimeError(f'{tool} failed (exit {result.returncode}); source remains unchanged')
    return result.stdout


def sql(dsn, query):
    return run(dsn, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query).decode().strip()


def manifest(dsn, schemas):
    result = {}
    for label, schema in schemas.items():
        tables = json.loads(sql(dsn, 'SELECT COALESCE(json_agg(c.relname ORDER BY c.relname),\'[]\') '
                               'FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace '
                               f'WHERE n.nspname={literal(schema)} AND c.relkind IN (\'r\',\'p\',\'m\')'))
        for table in tables:
            # A deterministic complete row representation; SQL performs an external
            # sort when needed. Stream into SHA-256 instead of retaining data in RAM.
            relation = ident(schema) + '.' + ident(table)
            query = f'COPY (SELECT row FROM (SELECT row_to_json(t)::text AS row FROM {relation} t) rows ORDER BY row COLLATE "C") TO STDOUT'
            env = connection_env(dsn)
            proc = subprocess.Popen(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
            digest, count = hashlib.sha256(), 0
            for chunk in iter(lambda: proc.stdout.read(1 << 20), b''):
                digest.update(chunk)
                count += chunk.count(b'\n')
            if proc.wait():
                raise RuntimeError('table verification failed')
            result[label + '.' + table] = {'rows': count, 'sha256': digest.hexdigest()}
        sequences = sql(dsn, 'SELECT COALESCE(json_agg(json_build_array(sequencename, increment_by, min_value, max_value, cache_size, cycle, last_value) ORDER BY sequencename),\'[]\') '
                        f'FROM pg_sequences WHERE schemaname={literal(schema)}')
        result[label + '.__sequences__'] = json.loads(sequences)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tenant-id', required=True)
    parser.add_argument('--source-env', default='SOURCE_DATABASE_URL')
    parser.add_argument('--target-env', default='SHARED_ADMIN_DATABASE_URL')
    parser.add_argument('--runtime-role', required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--source-stopped', action='store_true', required=True,
                        help='Confirm both logger and API writers have been stopped for this tenant')
    args = parser.parse_args()
    if not re.fullmatch('[a-z_][a-z0-9_]{0,62}', args.runtime_role):
        parser.error('invalid runtime role')
    source, target = os.environ[args.source_env], os.environ[args.target_env]
    schema = 'tenant_' + hashlib.sha256(args.tenant_id.encode()).hexdigest()[:32]
    private = schema + '_private'
    database_url(source, 'postgres')
    database_url(target, 'postgres')
    if source == target:
        parser.error('source and target must differ')
    args.work_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    os.chmod(args.work_dir, 0o700)
    if sql(target, f'SELECT count(*) FROM pg_namespace WHERE nspname IN ({literal(schema)}, {literal(private)})') != '0':
        raise RuntimeError('target schemas already exist; refusing to overwrite data')
    if sql(target, f'SELECT count(*) FROM pg_roles WHERE rolname={literal(schema)}') != '0':
        raise RuntimeError('target role already exists; refusing to reuse an unknown role')
    unexpected = sql(source, "SELECT count(*) FROM pg_namespace WHERE nspname NOT IN ('public','private','information_schema') AND nspname NOT LIKE 'pg_%'")
    if unexpected != '0':
        raise RuntimeError('source has additional schemas; inventory them before using the single-tenant copy tool')
    before = manifest(source, {'data': 'public', 'private': 'private'})
    original = args.work_dir / 'source.dump'
    run(source, 'pg_dump', '--format=custom', '--no-owner', '--no-acl', '--file', str(original))
    os.chmod(original, 0o600)
    stage = 'tm_migration_' + uuid.uuid4().hex
    stage_url = database_url(target, stage)
    sql(target, 'CREATE DATABASE ' + ident(stage))
    try:
        run(stage_url, 'pg_restore', '--no-owner', '--no-acl', '--exit-on-error', '--dbname', stage, str(original))
        # DDL renaming rewrites PostgreSQL object references, unlike text replacing
        # a SQL dump (which could change values inside historical records).
        sql(stage_url, f'ALTER SCHEMA public RENAME TO {ident(schema)}; CREATE SCHEMA public;')
        if sql(stage_url, "SELECT count(*) FROM pg_namespace WHERE nspname='private'") == '1':
            sql(stage_url, f'ALTER SCHEMA private RENAME TO {ident(private)};')
        else:
            sql(stage_url, f'CREATE SCHEMA {ident(private)};')
        extensions = json.loads(sql(stage_url, "SELECT COALESCE(json_agg(extname),'[]') FROM pg_extension WHERE extname IN ('cube','earthdistance')"))
        for ext in ('cube', 'earthdistance'):
            if ext in extensions:
                sql(stage_url, 'ALTER EXTENSION ' + ident(ext) + ' SET SCHEMA public')
        exported = args.work_dir / 'shared.dump'
        run(stage_url, 'pg_dump', '--format=custom', '--no-owner', '--no-acl', '--schema', schema,
            '--schema', private, '--file', str(exported))
        os.chmod(exported, 0o600)
        target_db = sql(target, 'SELECT current_database()')
        sql(target, f'CREATE ROLE {ident(schema)} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT; '
                    f'GRANT {ident(schema)} TO {ident(args.runtime_role)}; '
                    f'GRANT CREATE ON DATABASE {ident(target_db)} TO {ident(schema)};')
        try:
            run(target, 'pg_restore', '--no-owner', '--no-acl', '--single-transaction', '--exit-on-error',
                '--role', schema, '--dbname', target_db, str(exported))
        finally:
            sql(target, f'REVOKE CREATE ON DATABASE {ident(target_db)} FROM {ident(schema)}')
        after = manifest(target, {'data': schema, 'private': private})
        source_after = manifest(source, {'data': 'public', 'private': 'private'})
        report = {'tenant_id': args.tenant_id, 'schema': schema,
                  'verified': before == after == source_after,
                  'source': before, 'destination': after, 'source_after': source_after,
                  'activated': False}
        path = args.work_dir / 'verification.json'
        path.write_text(json.dumps(report, indent=2) + '\n')
        os.chmod(path, 0o600)
        if not report['verified']:
            raise RuntimeError('row/sequence verification failed or source changed; DO NOT activate destination')
        print('Verified copy created. Source retained. Review verification.json before updating the tenant assignment.')
    finally:
        sql(target, 'DROP DATABASE ' + ident(stage) + ' WITH (FORCE)')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        raise SystemExit(str(exc)) from None
