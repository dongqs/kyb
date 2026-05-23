# Redis Setup for kyb-infra

Run Redis 7 as a sidecar container on `kyb-net`, providing a shared cache
and session store for kyb-infra services.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                    kyb-net                       │
│              192.168.97.0/24                     │
│                                                  │
│  ┌──────────────────┐                            │
│  │  kyb-infra-redis │                            │
│  │  :6379            │                            │
│  │  (standalone)     │                            │
│  └──────────────────┘                            │
│                                                  │
│  ┌──────────────────┐                            │
│  │ kyb-infra-       │                            │
│  │ sing-box:2080    │  (SOCKS5 proxy)            │
│  └──────────────────┘                            │
└──────────────────────────────────────────────────┘

Host port mapping:
  6379 → kyb-infra-redis
```

## Container Specs

| Container Name  | Image         | Host Port | Data Volume  | Persistence Mode |
|-----------------|---------------|-----------|--------------|------------------|
| kyb-infra-redis | redis:7-alpine | 6379      | redis-data   | append-only file |

## Prerequisites

- `kyb-net` Docker network exists (created by kyb-infra stack)
- Port 6379 is free on the host
- Sing-box container `kyb-infra-sing-box` is running (provides `socks5://kyb-infra-sing-box:2080`)

## Volume

Redis persistent data (append-only file + optional RDB snapshots):

```bash
docker volume create redis-data
```

## Docker Run Command

```bash
docker run -d \
  --name kyb-infra-redis \
  --network kyb-net \
  --restart unless-stopped \
  -p 6379:6379 \
  -v redis-data:/data \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=localhost,127.0.0.1,kyb-net \
  redis:7-alpine \
  redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru
```

### What the flags do

| Flag / Env      | Purpose                                          |
|-----------------|--------------------------------------------------|
| `--network kyb-net` | Join kyb-infra network (reachable by container name) |
| `-p 6379:6379`  | Expose Redis on host port (for `redis-cli` from macOS) |
| `-v redis-data` | Persist AOF / RDB files across container restarts |
| `--restart unless-stopped` | Auto-restart on crash or host reboot    |
| `ALL_PROXY`     | Route outbound traffic through sing-box (for updates if needed) |
| `NO_PROXY`      | Bypass proxy for localhost and kyb-net traffic   |
| `--appendonly yes` | Append-only file persistence (every write)    |
| `--maxmemory`   | Limit Redis memory usage (512 MB)                |
| `--maxmemory-policy` | Eviction policy when memory limit is reached |

## Proxy Considerations

Redis itself does not need outbound internet access for normal operation.
However, setting `ALL_PROXY` ensures that if the `redis:7-alpine` image
ever needs to download updates or modules, it can reach the internet via
the sing-box SOCKS5 proxy.

`NO_PROXY=localhost,127.0.0.1,kyb-net` ensures internal traffic never
goes through the proxy.

## Memory Limits

Redis is primarily an in-memory data store. Without a limit, it could
consume all available RAM. The `--maxmemory 512mb` flag caps it at 512 MB,
with `allkeys-lru` eviction policy — Redis will evict the least-recently-used
keys when the limit is reached.

In practice:
- **Idle**: ~5-10 MB (no data)
- **Light use (caching)**: ~50-100 MB
- **Heavy use (session store + cache)**: ~200-512 MB

If you need more headroom, increase `--maxmemory` (e.g., `1gb`), but keep
an eye on total system memory (16 GB available).

## Verification

### Check the container is running

```bash
docker ps --filter name=kyb-infra-redis --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### From host (requires `redis-cli` on macOS)

```bash
redis-cli -h 127.0.0.1 -p 6379 PING
# Expected: PONG
```

If `redis-cli` is not installed on the host:

```bash
brew install redis  # includes redis-cli
```

### From another container on kyb-net

```bash
docker run --rm --network kyb-net redis:7-alpine redis-cli -h kyb-infra-redis -p 6379 PING
# Expected: PONG
```

### Verify persistence

```bash
# Write a key, kill the container, restart, and verify it's still there

docker exec kyb-infra-redis redis-cli SET test-key "hello persistence"
docker exec kyb-infra-redis redis-cli GET test-key
# Expected: "hello persistence"

docker restart kyb-infra-redis

docker exec kyb-infra-redis redis-cli GET test-key
# Expected: "hello persistence" (survived restart)

docker exec kyb-infra-redis redis-cli DEL test-key
```

### Check volume

```bash
docker volume inspect redis-data
docker run --rm -v redis-data:/data alpine ls -la /data
# Expected: appendonly.aof (and possibly dump.rdb)
```

## Connection Strings

### From inside kyb-net containers (e.g., sandboxes)

```
redis://kyb-infra-redis:6379
```

### From macOS host (via Orbstack port mapping)

```
redis://127.0.0.1:6379
```

## Security Considerations

1. **No authentication** — Redis is on an internal bridge network (`kyb-net`)
   and is only reachable from other containers on that network or from the
   macOS host via port mapping. No password is set for simplicity.

2. **Append-only file** — Every write is logged to `appendonly.aof` on the
   `redis-data` volume. This provides crash-safe persistence with minimal
   data loss.

3. **Memory limit** — `--maxmemory 512mb` prevents Redis from consuming all
   host RAM. The `allkeys-lru` eviction policy ensures the cache doesn't
   grow unbounded.

4. **No RDB snapshots by default** — AOF is sufficient for the use case.
   RDB snapshots can be enabled via `--save '900 1'` if point-in-time
   recovery is needed, but AOF already provides better durability.

## Differences from PostgreSQL Containers

| Aspect          | PostgreSQL                          | Redis                             |
|-----------------|-------------------------------------|-----------------------------------|
| Image           | `postgres:16` (175 MB)             | `redis:7-alpine` (12 MB)          |
| Data volume     | `pg16-data`                         | `redis-data`                      |
| Persistence     | WAL + data files                    | AOF (append-only file)            |
| Memory usage    | 50-500 MB                           | 5-512 MB                          |
| Host port       | 5436 (PG16)                         | 6379                              |
| Connection from host | `psql -h 127.0.0.1 -p 5436`   | `redis-cli -h 127.0.0.1 -p 6379` |

## Health Check (Optional)

Redis 7 on Alpine does not ship a health check script by default, but you
can add one with a `HEALTHCHECK` instruction in a custom Dockerfile or use
Docker's `--health-cmd`:

```bash
# Not in the run command above, but can be added:
docker run -d \
  --name kyb-infra-redis \
  --network kyb-net \
  --restart unless-stopped \
  -p 6379:6379 \
  -v redis-data:/data \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=localhost,127.0.0.1,kyb-net \
  --health-cmd="redis-cli -h 127.0.0.1 -p 6379 PING || exit 1" \
  --health-interval=10s \
  --health-timeout=3s \
  --health-retries=3 \
  redis:7-alpine \
  redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru
```

## Checking Logs

```bash
# Tail logs
docker logs -f kyb-infra-redis

# Check startup (look for AOF loading, port binding)
docker logs kyb-infra-redis 2>&1 | head -20

# Monitor memory usage
docker stats kyb-infra-redis --no-stream
```

## Cleanup

```bash
docker stop kyb-infra-redis
docker rm kyb-infra-redis
docker volume rm redis-data
```

## Troubleshooting

### "Could not connect" on port 6379

1. Check if another process is using port 6379 on the host:
   ```bash
   lsof -i :6379
   ```

2. Verify the container is running:
   ```bash
   docker ps --filter name=kyb-infra-redis
   ```

3. Test from within the container:
   ```bash
   docker exec kyb-infra-redis redis-cli PING
   ```

### Subscriber disconnected with "Client closed connection" (RESP3)

Some older Redis clients expect RESP2. Pin to RESP2 by starting with:
```bash
redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru --enable-protected-configs no
```

### AOF file corruption

If Redis fails to start due to a corrupt AOF file:

```bash
# Check the logs for AOF errors
docker logs kyb-infra-redis 2>&1 | grep -i aof

# Run redis-check-aof (inside the container)
docker exec kyb-infra-redis redis-check-aof --fix /data/appendonly.aof

# Restart
docker restart kyb-infra-redis
```

## Checklist

1. [ ] `docker pull redis:7-alpine`
2. [ ] `docker volume create redis-data`
3. [ ] Run the `docker run` command
4. [ ] Verify container is `Up`
5. [ ] Test from host: `redis-cli -h 127.0.0.1 -p 6379 PING`
6. [ ] Test from kyb-net: `docker run --rm --network kyb-net redis:7-alpine redis-cli -h kyb-infra-redis -p 6379 PING`
7. [ ] Verify AOF persistence works (set key, restart, get key)
8. [ ] Update dependent services to use `redis://kyb-infra-redis:6379`
