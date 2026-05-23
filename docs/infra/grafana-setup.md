# Grafana Setup for kyb-infra

## Overview

Grafana dashboards for ClickHouse and other kyb-infra metrics.

- Image: `grafana/grafana-oss:latest`
- Container: `kyb-infra-grafana`
- Network: `kyb-net`
- Port: `3000:3000`
- Volume: `grafana-storage:/var/lib/grafana`
- Plugin: `grafana-clickhouse-datasource`

## Prerequisites

- `kyb-net` Docker network exists (created by kyb-infra stack)
- ClickHouse HTTP endpoint is reachable at `http://host.orb.internal:8123`
- Sing-box container `kyb-infra-sing-box` is running (provides `socks5://kyb-infra-sing-box:2080`)
- Port 3000 is free on the host

## Volume

Grafana persistent data:

```bash
docker volume create grafana-storage
```

## Provisioning

A datasource for ClickHouse is auto-configured on first start via
Grafana provisioning. The config file lives at:

```
/home/dev/kyb/provisioning/datasources/clickhouse.yaml
```

It is mounted read-only into the container:

```bash
-v /home/dev/kyb/provisioning:/etc/grafana/provisioning:ro
```

### Adding more datasources

Drop additional YAML files into `/home/dev/kyb/provisioning/datasources/`.
Grafana picks them up on restart (provisioning is not hot-reloaded).

### Adding dashboards

Provision dashboards by creating a `dashboards/` directory alongside
`datasources/`:

```
/home/dev/kyb/provisioning/
  datasources/
    clickhouse.yaml
  dashboards/          # for provisioned dashboards
```

See [Grafana provisioning docs](https://grafana.com/docs/grafana/latest/administration/provisioning/)
for the YAML format.

## Docker Run

```bash
docker volume create grafana-storage

docker run -d \
  --name kyb-infra-grafana \
  --network kyb-net \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -v /home/dev/kyb/provisioning:/etc/grafana/provisioning:ro \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  grafana/grafana-oss:latest
```

### What the flags do

| Flag / Env | Purpose |
|---|---|
| `--network kyb-net` | Join kyb-infra network (reach sing-box, boss, etc.) |
| `-p 3000:3000` | Expose Grafana web UI |
| `-v grafana-storage` | Persistent database, plugins, config |
| `-v provisioning:ro` | Auto-configure ClickHouse datasource |
| `GF_INSTALL_PLUGINS` | Install ClickHouse datasource plugin on first start |
| `ALL_PROXY` | Route outbound traffic through sing-box |
| `NO_PROXY` | Bypass proxy for ClickHouse, localhost |

## Access

- URL: `http://localhost:3000`
- Default login: `admin` / `admin`
- Grafana will prompt you to change the password on first login.

After login, the **ClickHouse** datasource is already configured
(provisioned). You can start building dashboards immediately.

## Proxy Considerations

Grafana runs inside `kyb-net` so it needs the same proxy setup as other
infra containers:

- `ALL_PROXY=socks5://kyb-infra-sing-box:2080` — route external traffic
  through the sing-box SOCKS5 proxy.
- `NO_PROXY=host.orb.internal,localhost,127.0.0.1` — ensure ClickHouse
  connections (`host.orb.internal:8123`) bypass the proxy and go direct.

Without `NO_PROXY`, Grafana would try to reach ClickHouse through the
SOCKS5 proxy. Since `host.orb.internal` resolves to the host and
ClickHouse is not behind the proxy, queries would fail.

## Adding Your First Dashboard

1. Open `http://localhost:3000` and log in.
2. Click **Dashboards** (left sidebar) > **New** > **New Dashboard**.
3. Click **+ Add visualization**.
4. Select **ClickHouse** as the data source.
5. Write a query, e.g.:
   ```sql
   SELECT count() FROM system.tables
   ```
6. Click **Run query** to verify connectivity.
7. Save the dashboard.

For production-grade ClickHouse dashboards, consider importing these
community dashboards:

- [ClickHouse Dashboard](https://grafana.com/grafana/dashboards/21165-clickhouse-dashboard/)
- [ClickHouse Queries](https://grafana.com/grafana/dashboards/21432-clickhouse-queries/)

## Checking Logs

```bash
# Tail logs
docker logs -f kyb-infra-grafana

# Check plugin installation
docker logs kyb-infra-grafana 2>&1 | grep -i plugin

# Verify datasource provisioning
docker exec kyb-infra-grafana cat /etc/grafana/provisioning/datasources/clickhouse.yaml
```

## Cleanup

```bash
docker stop kyb-infra-grafana
docker rm kyb-infra-grafana
docker volume rm grafana-storage
```

## Troubleshooting

### "Plugin not found" on startup

The `GF_INSTALL_PLUGINS` env var downloads plugins on first start.
If the container already started without it, either recreate the
container or install manually:

```bash
docker exec -u root kyb-infra-grafana grafana cli plugins install grafana-clickhouse-datasource
docker restart kyb-infra-grafana
```

### ClickHouse datasource shows "Bad Gateway" or "Connection refused"

1. Verify ClickHouse HTTP is reachable from within the container:
   ```bash
   docker exec kyb-infra-grafana curl -s http://host.orb.internal:8123 --data-binary 'SELECT 1'
   ```
2. Check that `NO_PROXY=host.orb.internal` is set (otherwise the SOCKS5
   proxy will intercept ClickHouse traffic).
3. Confirm the ClickHouse server is listening on port 8123:
   ```bash
   curl -s http://host.orb.internal:8123 --data-binary 'SELECT 1'
   ```
