# Grafana Deployment

> Deploy Grafana for kyb-infra with ClickHouse and PostgreSQL datasources. Covers Docker run, provisioning, API usage, and common pitfalls.

## Overview

- **Image**: `grafana/grafana:latest` (or pinned `docker.1ms.run/grafana/grafana:11.5.2`)
- **Container**: `kyb-infra-grafana`
- **Network**: `kyb-net`
- **Port**: `3000`
- **Volume**: `grafana-storage:/var/lib/grafana`
- **Plugins**: `grafana-clickhouse-datasource`

## Docker Run

### Create volume

```bash
docker volume create grafana-storage
mkdir -p /home/dev/kyb/provisioning/datasources
```

### Start container

```bash
docker run -d \
  --name kyb-infra-grafana \
  --network kyb-net --restart unless-stopped \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -v /home/dev/kyb/provisioning:/etc/grafana/provisioning:ro \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  grafana/grafana:latest
```

### What the flags do

| Flag / Env               | Purpose                                                |
|--------------------------|--------------------------------------------------------|
| `--network kyb-net`      | Join kyb-infra network (reach sing-box, ClickHouse)    |
| `-p 3000:3000`           | Expose Grafana web UI                                  |
| `-v grafana-storage`     | Persistent database, plugins, config                   |
| `-v provisioning:ro`     | Auto-configure datasources (ClickHouse, PostgreSQL)    |
| `GF_INSTALL_PLUGINS`     | Install ClickHouse datasource plugin on first start    |
| `ALL_PROXY`              | Route outbound traffic through sing-box                |
| `NO_PROXY`               | Bypass proxy for ClickHouse, localhost                 |

## Datasource Provisioning

### ClickHouse datasource YAML

Save as `/home/dev/kyb/provisioning/datasources/clickhouse.yaml`:

```yaml
apiVersion: 1

datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    url: http://host.orb.internal:8123
    jsonData:
      server: host.orb.internal
      port: 8123
      protocol: native
      defaultDatabase: kyb
    access: proxy
    isDefault: false
```

> **Important for CK plugin v4+**: Use `jsonData.server`, not `url`. The v4 plugin ignores the `url` field. Without `jsonData.server`, the datasource shows "Bad Gateway" or "Datasource is misconfigured".

### PostgreSQL datasource YAML

Save as `/home/dev/kyb/provisioning/datasources/pg-datasource.yaml`:

```yaml
apiVersion: 1

datasources:
  - name: PostgreSQL
    type: postgres
    url: host.orb.internal:5432
    database: postgres
    user: postgres
    jsonData:
      sslmode: disable
    secureJsonData:
      password: postgres
    access: proxy
    isDefault: true
```

### Adding more datasources

Drop additional YAML files into `/home/dev/kyb/provisioning/datasources/`. Grafana picks them up on restart (provisioning is not hot-reloaded -- the container must be restarted).

### Provisioned dashboards

To provision dashboards, create a directory alongside `datasources/`:

```
/home/dev/kyb/provisioning/
  datasources/
    clickhouse.yaml
    pg-datasource.yaml
  dashboards/
    dashboard-1.json
```

Add a `dashboards.yaml` provisioning file in `/home/dev/kyb/provisioning/dashboards/` or add it under a separate provisioning directory. See [Grafana provisioning docs](https://grafana.com/docs/grafana/latest/administration/provisioning/) for the YAML format.

## Proxy Considerations

Grafana runs inside `kyb-net` so it needs the same proxy setup as other infra containers:

- `ALL_PROXY=socks5://kyb-infra-sing-box:2080` -- route external traffic through the sing-box SOCKS5 proxy.
- `NO_PROXY=host.orb.internal,localhost,127.0.0.1` -- ensure ClickHouse and PostgreSQL connections bypass the proxy.

Without `NO_PROXY`, Grafana would try to reach ClickHouse through the SOCKS5 proxy. Since `host.orb.internal` resolves to the host and ClickHouse is not behind the proxy, queries would fail with connection timeout.

## Add a Dashboard via API

```bash
# 1. Get API key (admin/admin credentials)
curl -s -X POST http://127.0.0.1:3000/api/auth/keys \
  -H "Content-Type: application/json" \
  -d '{"name":"deploy-key","role":"Admin"}' \
  -u admin:admin

# 2. Create a simple dashboard
curl -s -X POST http://127.0.0.1:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <API_KEY>" \
  -d '{
    "dashboard": {
      "title": "CK Health",
      "panels": [
        {
          "title": "Query 1",
          "type": "timeseries",
          "datasource": "ClickHouse",
          "targets": [
            {
              "query": "SELECT toStartOfMinute(now()) AS t, count() AS v FROM system.tables",
              "format": "timeseries",
              "datasource": "ClickHouse"
            }
          ]
        }
      ]
    },
    "overwrite": true
  }'
```

> **Important**: With Grafana ClickHouse plugin v4, the `format` field must be `"timeseries"` (not `"time_series"`). The old `"time_series"` value is silently ignored, resulting in an empty panel.

## Access

- **URL**: `http://localhost:3000`
- **Default login**: `admin` / `admin`
- Grafana prompts you to change the password on first login.

## Checking Health

```bash
# Grafana API health endpoint
curl http://127.0.0.1:3000/api/health
# Expected: { "database": "ok", ... }
```

## How to Reset Admin Password

```bash
# Enter the container
docker exec -it kyb-infra-grafana bash

# Use grafana-cli to reset
grafana-cli admin reset-admin-password newpassword
exit

# Or if the CLI is unavailable, delete the users.db and restart:
docker stop kyb-infra-grafana
docker run --rm -v grafana-storage:/data alpine rm -f /data/grafana.db
docker start kyb-infra-grafana
# Grafan will recreate the DB and admin/admin works again
```

## How to Check Logs

```bash
# Container logs
docker logs -f kyb-infra-grafana

# Plugin installation status
docker logs kyb-infra-grafana 2>&1 | grep -i plugin

# Verify provisioning files mounted correctly
docker exec kyb-infra-grafana ls -la /etc/grafana/provisioning/datasources/

# Check if CK plugin is installed
docker exec kyb-infra-grafana grafana cli plugins ls
```

## Common Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| **Docker Hub mirror 429** | Pull fails with `429 Too Many Requests` on `grafana/grafana-oss:latest` | Use a mirror: `docker.1ms.run/grafana/grafana:11.5.2`. Or pull through the local registry cache (see registry-cache-deploy.md). |
| **CK plugin v4 misconfig** | Datasource shows "Bad Gateway" or "Datasource is misconfigured" | Use `jsonData.server` in provisioning YAML, not `url`. |
| **Wrong format value** | CK query returns data but Grafana panel is empty | Change `"time_series"` to `"timeseries"` in the query model. The v4 CK plugin only accepts the new format string. |
| **Provisioning dir not propagated** | No datasources appear after container start | The bind mount might not have propagated. Restore with: `docker cp /home/dev/kyb/provisioning/datasources/ kyb-infra-grafana:/etc/grafana/provisioning/datasources/` then restart. |
| **Password change breaks datasources** | After resetting admin password, provisioned datasources stop working | No -- provisioned datasources use their own credentials from the YAML file. Admin password does not affect them. If a datasource fails after password change, it is likely a connectivity issue, not auth. |
| **host.orb.internal unreachable from Grafana** | CK datasource shows "Connection refused" or timeout | Check if Grafana can resolve the host: `docker exec kyb-infra-grafana ping host.orb.internal` (may need `ping` installed). Ensure NO_PROXY includes host.orb.internal. If host.orb.internal does not resolve (non-Orbstack), use host IP or host.docker.internal instead. |
| **PostgreSQL datasource connection refused** | PG datasource shows "Unable to connect" | Check that the PG host is reachable from the Grafana container: `docker exec kyb-infra-grafana nc -zv postgres-host 5432`. Ensure the PG host allows connections from Docker network IPs. |
| **Plugin not found at startup** | Grafana starts but CK plugin is missing | Install manually: `docker exec -u root kyb-infra-grafana grafana cli plugins install grafana-clickhouse-datasource && docker restart kyb-infra-grafana` |

## Cleanup

```bash
docker stop kyb-infra-grafana
docker rm kyb-infra-grafana
docker volume rm grafana-storage  # WARNING: deletes all data and config
```

## References

- [Grafana Docker Docs](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/)
- [Provisioning Datasources](https://grafana.com/docs/grafana/latest/administration/provisioning/#datasources)
- [ClickHouse Grafana Plugin](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/)
## 附錄 (中文版概要)

### 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-grafana |
| 镜像 | grafana/grafana-oss:latest |
| 端口 | 3000 |
| 网络 | kyb-net |

### 登录

默认 admin/admin，首次登录要求改密码。

### 创建大盘 (API)

```bash
curl -s -X POST -u admin:admin http://127.0.0.1:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"title":"My Dashboard","panels":[...]}, "overwrite":true}'
```

### 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| 镜像拉不动 | docker.xuanyuan.me 429 | `docker pull docker.1ms.run/grafana/grafana:11.5.2` |
| 面板空白 "invalid format" | `format: "time_series"` 不对 | 改为 `"timeseries"` |
| 面板空白 "server not set" | CK v4 插件缺 `jsonData.server` | provisioning 加 `jsonData: { server: host.orb.internal }` |
| provisioning 配置没生效 | bind mount 没传播 | `docker cp` 替代 volume mount |
| 改密码后数据源没了 | 密码和 provisioning 无关 | 重新 provisioning 或手动加 |
