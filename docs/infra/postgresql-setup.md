# PostgreSQL Multi-Version Setup on kyb-infra

Run PostgreSQL 14, 15, 16, 17 as sidecar containers on `kyb-net`, replacing
the current pattern of running PG16 inside sandbox containers.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                    kyb-net                       │
│              192.168.97.0/24                     │
│                                                  │
│  ┌──────────────┐  ┌──────────────┐              │
│  │  kyb-infra-  │  │  kyb-infra-  │              │
│  │ postgresql-14 │  │ postgresql-15 │              │
│  │  :5432        │  │  :5432        │              │
│  └──────────────┘  └──────────────┘              │
│                                                  │
│  ┌──────────────┐  ┌──────────────┐              │
│  │  kyb-infra-  │  │  kyb-infra-  │              │
│  │ postgresql-16 │  │ postgresql-17 │              │
│  │  :5432        │  │  :5432        │              │
│  └──────────────┘  └──────────────┘              │
│                                                  │
│  ┌──────────────────┐                            │
│  │ kyb-infra-       │                            │
│  │ sing-box:2080    │  (SOCKS5 proxy)            │
│  └──────────────────┘                            │
└──────────────────────────────────────────────────┘

Host port mapping:
  5434 → kyb-infra-postgresql-14
  5435 → kyb-infra-postgresql-15
  5436 → kyb-infra-postgresql-16
  5437 → kyb-infra-postgresql-17
```

## Container Specs

| Container Name            | PG Ver | Image          | Host Port | Data Volume        |
|---------------------------|--------|----------------|-----------|--------------------|
| kyb-infra-postgresql-14   | 14     | postgres:14    | 5434      | pg14-data          |
| kyb-infra-postgresql-15   | 15     | postgres:15    | 5435      | pg15-data          |
| kyb-infra-postgresql-16   | 16     | postgres:16    | 5436      | pg16-data          |
| kyb-infra-postgresql-17   | 17     | postgres:17    | 5437      | pg17-data          |

## Docker Run Commands

### 1. PostgreSQL 14

```bash
docker run -d \
  --name kyb-infra-postgresql-14 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5434:5432 \
  -v pg14-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:14
```

### 2. PostgreSQL 15

```bash
docker run -d \
  --name kyb-infra-postgresql-15 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5435:5432 \
  -v pg15-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:15
```

### 3. PostgreSQL 16

```bash
docker run -d \
  --name kyb-infra-postgresql-16 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5436:5432 \
  -v pg16-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:16
```

### 4. PostgreSQL 17

```bash
docker run -d \
  --name kyb-infra-postgresql-17 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5437:5432 \
  -v pg17-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:17
```

## Authentication

Use `POSTGRES_HOST_AUTH_METHOD=trust` to match the current sandbox pattern
(trust auth, no password required within kyb-net).

After first start, verify pg_hba.conf inside the container:

```bash
docker exec kyb-infra-postgresql-16 bash -c "cat /var/lib/postgresql/data/pg_hba.conf"
```

Expected lines (set automatically by `POSTGRES_HOST_AUTH_METHOD=trust`):

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             0.0.0.0/0               trust
```

No proxy env vars needed — PG containers are on kyb-net and communicate
directly. They do not need outbound internet access for normal operation.

## Connection Strings

### From inside kyb-net containers (e.g., sandboxes)

| PG Ver | Connection String                                                    |
|--------|----------------------------------------------------------------------|
| 14     | `postgresql://postgres:postgres@kyb-infra-postgresql-14:5432/postgres` |
| 15     | `postgresql://postgres:postgres@kyb-infra-postgresql-15:5432/postgres` |
| 16     | `postgresql://postgres:postgres@kyb-infra-postgresql-16:5432/postgres` |
| 17     | `postgresql://postgres:postgres@kyb-infra-postgresql-17:5432/postgres` |

### From macOS host (via Orbstack port mapping)

| PG Ver | Connection String                                              |
|--------|----------------------------------------------------------------|
| 14     | `postgresql://postgres:postgres@127.0.0.1:5434/postgres`       |
| 15     | `postgresql://postgres:postgres@127.0.0.1:5435/postgres`       |
| 16     | `postgresql://postgres:postgres@127.0.0.1:5436/postgres`       |
| 17     | `postgresql://postgres:postgres@127.0.0.1:5437/postgres`       |

## Data Migration (PG16 Only)

If there is existing PG16 data inside sandbox containers that needs to be
moved to the new `kyb-infra-postgresql-16` container:

### Step 1: Dump from old PG16 (running inside a sandbox)

```bash
# From within the sandbox that has the old PG16
pg_dumpall -U postgres -h localhost > /tmp/pg16-dump.sql
```

Or from the host if port is exposed:

```bash
pg_dumpall -U postgres -h 127.0.0.1 -p 5432 > /tmp/pg16-dump.sql
```

### Step 2: Copy dump into new container

```bash
docker cp /tmp/pg16-dump.sql kyb-infra-postgresql-16:/tmp/pg16-dump.sql
```

### Step 3: Restore into new PG16

```bash
docker exec -i kyb-infra-postgresql-16 psql -U postgres -f /tmp/pg16-dump.sql
```

Or pipe directly:

```bash
pg_dumpall -U postgres -h <old-pg-host> -p <old-pg-port> \
  | docker exec -i kyb-infra-postgresql-16 psql -U postgres
```

## Resource Impact

| Resource   | Per PG Instance | 4 Instances Total | Available | Verdict |
|------------|-----------------|-------------------|-----------|---------|
| RAM (idle) | ~50-100 MB      | ~200-400 MB       | 9.2 GiB   | OK     |
| RAM (load) | ~200-500 MB     | ~800 MB - 2 GiB   | 9.2 GiB   | OK     |
| CPU        | ~0-5% idle      | ~0-20% idle       | M-series  | OK     |
| Disk       | ~100 MB empty   | ~400 MB empty     | plenty    | OK     |
| Ports      | 1 host port     | 4 host ports      | free      | OK     |

## Verification

### Check all containers are running

```bash
docker ps --filter name=kyb-infra-postgresql --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Test connection to each version

```bash
# Via Docker network (from another container on kyb-net)
docker run --rm --network kyb-net postgres:16 psql \
  -h kyb-infra-postgresql-14 -U postgres -c "SELECT version();"

# From host
psql -h 127.0.0.1 -p 5434 -U postgres -c "SELECT version();"
psql -h 127.0.0.1 -p 5435 -U postgres -c "SELECT version();"
psql -h 127.0.0.1 -p 5436 -U postgres -c "SELECT version();"
psql -h 127.0.0.1 -p 5437 -U postgres -c "SELECT version();"
```

### Check data volumes

```bash
docker volume ls | grep pg
docker run --rm -v pg14-data:/data alpine ls /data
```

## Cleanup

### Remove a single PG container + volume

```bash
docker stop kyb-infra-postgresql-14
docker rm kyb-infra-postgresql-14
docker volume rm pg14-data
```

### Remove all PG containers + volumes

```bash
for v in 14 15 16 17; do
  docker stop "kyb-infra-postgresql-$v" 2>/dev/null
  docker rm "kyb-infra-postgresql-$v" 2>/dev/null
  docker volume rm "pg${v}-data" 2>/dev/null
done
```

## Change Management

### When updating project connection strings

Before (sandbox-local PG16):

```
postgresql://postgres:postgres@localhost:5432/postgres
```

After (kyb-infra managed PG):

```
postgresql://postgres:postgres@kyb-infra-postgresql-16:5432/postgres
```

### Checklist

1. [ ] `docker pull postgres:14 postgres:15 postgres:16 postgres:17`
2. [ ] Run the 4 `docker run` commands
3. [ ] Verify all 4 containers are `Up` and healthy
4. [ ] Test connections from host (127.0.0.1:5434-5437)
5. [ ] Test connections from another kyb-net container (by container name)
6. [ ] Migrate data from old PG16 if needed (pg_dump/pg_restore)
7. [ ] Update project `.env` files or `mig25` configs to point to new PG hosts
8. [ ] Stop old sandbox containers that ran PG16 internally
9. [ ] Profit
