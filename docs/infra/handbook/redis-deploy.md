# Redis 部署手册

## 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-redis |
| 镜像 | redis:7-alpine |
| 端口 | 6379 |
| 网络 | kyb-net |

## Docker Run

```bash
docker volume create redis-data
docker run -d --name kyb-infra-redis \
  --network kyb-net --restart unless-stopped \
  -p 6379:6379 \
  -v redis-data:/data \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=localhost,127.0.0.1,kyb-infra-* \
  redis:7-alpine \
  redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru
```

## 验证

```bash
# 从 kyb-net 内容器
docker run --rm --network kyb-net redis:7-alpine redis-cli -h kyb-infra-redis -p 6379 PING
# → PONG
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| OOM kill | 没设 `--maxmemory` | 加 `--maxmemory 512mb --maxmemory-policy allkeys-lru` |
| 重启丢数据 | 没开 AOF | 加 `--appendonly yes` 并挂 volume |
| 连不上 | 网络不对 | 确认 `--network kyb-net` |
