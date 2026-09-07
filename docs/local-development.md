# Local development and regression tests

The portable installer uses PostgreSQL 14+ without extensions, AWS IAM, Flyway,
or a scheduler. It is for a new empty development database. It applies schema
setup plus migrations V5–V12 in one transaction and refuses an existing
installation or application objects. Use versioned migrations for upgrades.

## Docker

```sh
make up
make install-docker
make demo-docker
make test-docker
make down
```

Docker Compose starts PostgreSQL 16 at `localhost:55432`, with database, user,
and development password all `rollup`. The port is bound to loopback only.
`make up` can be repeated; run the install target once per empty database.
`make down` preserves the named data volume. `make test-docker` uses a separate
temporary cluster and does not connect to the development database.

Set `POSTGRES_PORT` to change the published Docker port. If you also use the
host-side targets, set `DATABASE_URL` with that matching port.

## Existing PostgreSQL server

Create a new database using an administrative role, then run:

```sh
export DATABASE_URL='postgresql://your_admin@localhost/rollup_dev'
make install
make demo
```

The administrator needs permission to create schemas and the `db_ecs_user`
role. The installer creates that role with `NOLOGIN` only if it does not exist;
an existing role is left unchanged. It grants schema usage and table/sequence
default privileges for objects created by the installing role. It does not
configure an application login or grant schema creation to the application.

`make demo` runs [the example SQL](../examples/quickstart.sql), including a
late correction and a repeated bucket refresh. It owns two `demo_` tables and
can be repeated. The fixture timestamps are fixed historical dates; its rollup
is inactive so scheduled workers do not spend time catching up this example.

## Regression suite

With local PostgreSQL server binaries installed:

```sh
make shell-check
make test
```

The runner discovers PostgreSQL binaries using `pg_config`, or uses `PG_BIN`
when provided. It creates a private temporary cluster, disables TCP listening,
installs all migrations, runs `tests/*.sql` followed by `tests/*.sh`, and stops
and removes the cluster on exit. No existing database is used by default:
`DATABASE_URL` is deliberately ignored by the test runner.

```sh
PG_BIN=/path/to/postgresql/bin make test
```

For CI or a machine without `initdb`, explicitly supply a new disposable
database. The database must be empty and the test role needs `CREATEDB` for
the upgrade test's separate temporary database. Fixtures may remain after the suite:

```sh
TEST_DATABASE_URL='postgresql://test_admin@localhost/rollup_test' make test
```

SQL test files receive a separate `psql` session with `ON_ERROR_STOP=1`. Each
test controls its own transaction, so fixtures can use `BEGIN` / `ROLLBACK`.
Shell tests inherit `TEST_DATABASE_URL`. The upgrade test installs the historical
V10 schema into a separate database, seeds legacy data, applies V11/V12, checks
preservation and backfill, and drops that database on exit. CI runs the same suite
on PostgreSQL 14, 16, and 17.

The portable installer does not record Flyway history. Do not point the
historical foundational Flyway configuration at a portable installation:
that configuration also contains cloud extension and IAM setup. An existing
Flyway-managed deployment should apply new migrations through its current
migration process after staging validation.
