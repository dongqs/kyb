# Mac 重启指南 — kyb-infra 安全上下线

> 2026-05-25 · 踩坑验证版
> 上回重启教训：sing-box OOM + nuc8 IP 漂移

---

## 下线（Mac 重启前）

依赖顺序：开发容器 → 可观测性 → nuc8 → sing-box（代理最后关）

```bash
# 1. 停开发容器（Claude agent 们）
docker stop kyb-click-xiaoye kyb-kyb-architecturer kyb-hamilton-cat

# 2. 停基础设施
docker stop kyb-infra-clickhouse

# 3. 停 nuc8 隧道（GitLab 出口）
docker stop kyb-infra-nuc8-tunnel

# 4. 最后停代理（全集群网络依赖它）
docker stop kyb-infra-sing-box
```

停完 → 重启 Mac。

---

## 上线（Mac 重启后）

依赖顺序：sing-box → nuc8 → CK → 开发容器

**重要：每一步都要等上一步确认通了再继续。**

### Step 0：确认 Docker 在跑

```bash
docker ps
# 应该看到几个容器在重启中
```

### Step 1：起代理

```bash
docker start kyb-infra-sing-box
sleep 3

# 验证：GitHub 通了吗？
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI --max-time 5 https://github.com
# 应该返回: HTTP/2 200
```

如果 sing-box 反复重启（上次 256m OOM 的坑）：
```bash
# 去掉了内存限制就不应该出这个问题
# 如果还重启，检查日志：
docker logs kyb-infra-sing-box --tail 10
```

### Step 2：起 nuc8 隧道

```bash
docker start kyb-infra-nuc8-tunnel
sleep 5

# 验证：GitLab 通了吗？
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI --max-time 10 https://git.leyantech.com
# 应该返回: HTTP/2 302
```

**⚠️ 如果 GitLab 不通（上次的坑）：**
nuc8-tunnel 重建后 IP 会漂，sing-box 配置里还是旧 IP。
```bash
# 检查隧道实际 IP
docker inspect kyb-infra-nuc8-tunnel \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# 检查 sing-box 配置里的 IP
docker exec kyb-infra-sing-box grep "nuc8-proxy" -A3 /etc/sing-box/config.json

# 如果 IP 对不上，修配置：
docker run --rm -v sb-config-v2:/cfg alpine sh -c \
  "sed -i 's/旧IP/新IP/' /cfg/config.json"
docker kill -s HUP kyb-infra-sing-box
```

### Step 3：起可观测性

```bash
docker start kyb-infra-clickhouse
sleep 3
clickhouse-client -q "SELECT 1"
# 应该返回: 1
```

### Step 4：恢复开发容器

```bash
docker start kyb-click-xiaoye kyb-kyb-architecturer
```

需要 Claude 会话的：
```bash
# architecturer
docker exec -u dev kyb-kyb-architecturer bash -l -c \
  "claude --resume 99ad09b6-25a8-476b-848a-0239d028532f"
```

---

## 验证清单

```bash
# GitHub
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI --max-time 5 https://github.com
# → 200

# GitLab
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI --max-time 10 https://git.leyantech.com
# → 302

# DeepSeek API
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI --max-time 5 https://api.deepseek.com
# → 401（正常——说明连得上）

# PostgreSQL
pg_isready
# → accepting connections

# ClickHouse
clickhouse-client -q "SELECT count() FROM infra.container_logs"
# → 数字（或 0）

# 所有容器
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

---

## 5 分钟内搞不定？

```bash
# 把日志贴到 issue 里，我来诊断
docker logs kyb-infra-sing-box --tail 20 > /tmp/sing-box.log
docker logs kyb-infra-nuc8-tunnel --tail 20 > /tmp/nuc8-tunnel.log
```
