# Grafana 部署手册

## 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-grafana |
| 镜像 | grafana/grafana-oss:latest |
| 端口 | 3000 |
| 网络 | kyb-net |

## Docker Run

```bash
docker volume create grafana-storage
mkdir -p /home/dev/kyb/provisioning/datasources

cat > /home/dev/kyb/provisioning/datasources/clickhouse.yaml << 'YAML'
apiVersion: 1
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    access: proxy
    url: http://host.orb.internal:8123
    isDefault: true
    jsonData:
      server: host.orb.internal
      port: 8123
      protocol: http
YAML

docker run -d --name kyb-infra-grafana \
  --network kyb-net --restart unless-stopped \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -v /home/dev/kyb/provisioning:/etc/grafana/provisioning:ro \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  grafana/grafana-oss:latest
```

## 登录

默认 admin/admin，首次登录要求改密码。

## 创建大盘 (API)

```bash
curl -s -X POST -u admin:admin http://127.0.0.1:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"title":"My Dashboard","panels":[...]}, "overwrite":true}'
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| 镜像拉不动 | docker.xuanyuan.me 429 | `docker pull docker.1ms.run/grafana/grafana:11.5.2` |
| 面板空白 "invalid format" | `format: "time_series"` 不对 | 改为 `"timeseries"` |
| 面板空白 "server not set" | CK v4 插件缺 `jsonData.server` | provisioning 加 `jsonData: { server: host.orb.internal }` |
| provisioning 配置没生效 | bind mount 没传播 | `docker cp` 替代 volume mount |
| 改密码后数据源没了 | 密码和 provisioning 无关 | 重新 provisioning 或手动加 |
