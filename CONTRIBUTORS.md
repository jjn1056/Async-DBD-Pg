# Contributing to Async::DBD::Pg

## Development Setup

### Prerequisites

- Perl 5.18+
- Docker and Docker Compose for local PostgreSQL
- Dist::Zilla for building releases

```bash
cpanm Dist::Zilla
dzil listdeps --missing | cpanm
```

### Start the Test Database

```bash
docker compose up -d
docker compose ps
docker compose logs -f postgres
```

The default local test database is:

| Setting | Value |
|---------|-------|
| Host | localhost |
| Port | 5432 |
| User | postgres |
| Password | test |
| Database | test |

If something already occupies port 5432, set `PG_PORT` to publish it
elsewhere and point `TEST_PG_DSN` at the same port:

```bash
PG_PORT=5433 docker compose up -d
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

### Run the Tests

```bash
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -r -l t/
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -r -l -v t/
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -l t/integration/connection.t
prove -l t/unit/
```

### Stop the Test Database

```bash
docker compose stop
docker compose down
docker compose down -v
```

### Run Examples

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/01-basic-query/app.pl
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/06-pubsub/app.pl
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/07-job-queue/app.pl
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/08-live-dashboard/app.pl
```
