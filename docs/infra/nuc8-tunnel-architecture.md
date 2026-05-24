# nuc8 隧道架构 — GitLab 出站代理

> **状态：** 已上线（2026-05-24）
> **核心容器：** `kyb-infra-nuc8-tunnel`（`restart: always`）

---

## 问题背景

GitLab（`git.leyantech.com`）有 IP 白名单，只允许办公室网络（120.132.11.237）和 nuc8 的 IP 访问。所有外部请求都需要从 nuc8 的 IP 出站。

之前的方式是 SSH 隧道跑在 `kyb-infra-boss` 容器里（PID 1 的 autossh 进程）。但这个容器是 `restart: unless-stopped` 的——boss 被 kill 时隧道也随之死亡，导致所有走 nuc8-proxy 出站的流量全部中断（包括 GitLab 访问）。

**教训：** 关键网络隧道不能依赖 ephemeral 容器。它们需要自己的 `restart: always` 容器。

---

## 架构演进

### 阶段 1：隧道跑在 boss 内部（已废弃）

```
kyb-infra-boss (restart: unless-stopped)
  ├── Claude agent (tmux)
  └── SSH -D 2081 → nuc8 (PID 1 autossh)  ← 脆弱！
```

问题：
- boss 容器被 kill → 隧道死
- 隧道重启需要重建整个 boss 容器
- 隧道跟 Claude session 生命周期绑定，不合理

### 阶段 2：独立隧道容器（当前）

```
kyb-infra-nuc8-tunnel (restart: always)   ← 独立容器
  └── SSH -D 0.0.0.0:2081 → nuc8          ← 纯隧道，无 agent
```

- 隧道生命周期跟容器解耦
- `restart: always` 保证 Docker daemon 存活期间隧道永远在线
- 容器挂了自动重启，不需要人工干预

### 阶段 3：nuc8 原生 SOCKS5（规划中）

在 nuc8 上安装 `dante-server`，直接用 nuc8 做 SOCKS5 代理，不再需要 SSH 隧道：

```
nuc8:2081 (dante-server)                  ← 原生 SOCKS5
```

好处：
- 不依赖 SSH 连接稳定性
- 减少一跳（去掉隧道容器）
- nuc8 重启后服务自动恢复（systemd）

现状：dante-server 需要 nuc8 上 sudo 安装，目前没有 nuc8 的 root 权限。

---

## 当前拓扑

```
┌── 客户端 ──────────────────────────────────────┐
│  curl -x socks5://kyb-infra-sing-box:2080 ...   │
│  sing-box config: nuc8-proxy outbound →         │
│    192.168.97.3:2081                            │
└────────────────────────────────────────────────┘
                        │
                        ▼
┌── kyb-infra-nuc8-tunnel ────────────────────────┐
│  Container: kyb-base:latest                     │
│  Network: kyb-net                               │
│  Restart: always                                │
│  IP: 192.168.97.3 (kyb-net)                     │
│  Command: ssh -D 0.0.0.0:2081 -N               │
│    dongqs@100.98.29.39                          │
│  Mount: /Users/dongqs/.ssh → /root/.ssh:ro      │
│  Port: 2081 (SOCKS5, kyb-net only)              │
└────────────────────────────────────────────────┘
                        │ SSH -D (Tailscale 直连)
                        ▼
┌── nuc8 (100.98.29.39) ──────────────────────────┐
│  Tailscale 节点                                  │
│  办公室网络可达                                   │
│  → 未来: dante-server (SOCKS5 native)            │
└────────────────────────────────────────────────┘
                        │
                        ▼
┌── 办公室网络 ────────────────────────────────────┐
│  GitLab (git.leyantech.com) ✅                    │
│  其他内网服务 ✅                                  │
└────────────────────────────────────────────────┘
```

### 数据流

```
curl → sing-box (nuc8-proxy outbound: 192.168.97.3:2081)
     → kyb-infra-nuc8-tunnel (SSH -D :2081 → dongqs@100.98.29.39)
     → nuc8 (Tailscale 100.98.29.39)
     → 办公室网络 → git.leyantech.com ✅
```

---

## 容器规格

| 项目 | 值 |
|------|-----|
| 容器名 | `kyb-infra-nuc8-tunnel` |
| 镜像 | `kyb-base:latest` |
| 网络 | `kyb-net`（与 sing-box、boss 同网络） |
| kyb-net IP | `192.168.97.3`（静态分配） |
| 重启策略 | `restart: always` |
| 端口 | 2081（SOCKS5，仅在 kyb-net 内可达） |
| SSH 密钥 | 宿主机 `/Users/dongqs/.ssh`（只读挂载） |
| 内存限制 | 64MiB（SSH 进程极轻量） |
| Agent | 无（纯服务容器） |

---

## 创建与生命周期

### 创建

```bash
docker run -d --name kyb-infra-nuc8-tunnel \
  --restart always \
  --network kyb-net \
  --memory 64m \
  -v /Users/dongqs/.ssh:/root/.ssh:ro \
  kyb-base:latest \
  ssh -o ControlMaster=no \
      -o StrictHostKeyChecking=no \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -D 0.0.0.0:2081 \
      -N dongqs@100.98.29.39
```

### 停止

```bash
docker stop kyb-infra-nuc8-tunnel
```

注意：停止后所有 nuc8-proxy 出站流量会中断（GitLab 不可达）。如有备用路径，先切流量再停。

### 重启

```bash
docker restart kyb-infra-nuc8-tunnel
```

### 查看日志

```bash
docker logs kyb-infra-nuc8-tunnel --tail 20
```

### 删除重建

```bash
docker rm -f kyb-infra-nuc8-tunnel
# 然后执行上面的创建命令
```

---

## 故障排查

### 检查隧道是否存活

```bash
# 从容器的任何容器测试
ALL_PROXY=socks5://kyb-infra-nuc8-tunnel:2081 curl -sI https://git.leyantech.com
# 期望: HTTP/2 302 (重定向到登录页) = 正常

# 或通过 sing-box 代理链测试
ALL_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://git.leyantech.com
```

### 常见问题

| 现象 | 原因 | 修复 |
|------|------|------|
| `Connection refused` | 容器未运行 | `docker start kyb-infra-nuc8-tunnel` |
| `Connection timed out` | SSH 连不上 nuc8 | 检查 nuc8 Tailscale 状态 |
| `403 Forbidden` | 请求没走 nuc8 出站 | 检查 sing-box config nuc8-proxy outbound 地址 |
| 偶发断连 | SSH ServerAlive 超时 | 检查 SSH 参数，或重启容器 |
| 密钥错误 | SSH key 不匹配 | 检查 `/root/.ssh` 挂载是否正确 |

### SSH 连接诊断

```bash
# 直接 SSH 测试（在宿主机或网络可达的机器上）
ssh -v -o StrictHostKeyChecking=no dongqs@100.98.29.39

# 检查 nuc8 的 Tailscale 状态（需 SSH 到 nuc8）
ssh dongqs@100.98.29.39 'tailscale status'
```

### 容器内连接诊断

```bash
# 进入容器
docker exec -it kyb-infra-nuc8-tunnel sh

# 测试 SSH 连接（容器内）
ssh -v -o StrictHostKeyChecking=no dongqs@100.98.29.39

# 查看监听端口
ss -tlnp | grep 2081
```

---

## Belt-and-Suspenders: 双层保障

当前架构有两层保障，任一层的失效不会完全中断 nuc8 出站流量：

### 第一层：SSH 隧道容器（当前运行中）

`kyb-infra-nuc8-tunnel` 容器运行 SSH 反向 SOCKS5 代理，通过 Tailscale 直连 nuc8。

- `restart: always`：Docker daemon 存活期间自动恢复
- 极轻量（~20MB 内存），纯服务无 agent
- SSH keepalive 防断连

### 第二层：nuc8 原生 SOCKS5（规划中）

在 nuc8 上安装 `dante-server`，systemd 管理：

- systemd 自动恢复
- 不依赖 SSH 连接
- nuc8 重启后自愈

### 故障切换

当第二层就绪后，sing-box 配置可以配置主备出站：

```json
{
  "outbounds": [
    {
      "tag": "nuc8-proxy",
      "type": "socks",
      "server": "192.168.97.3",
      "server_port": 2081
    },
    {
      "tag": "nuc8-proxy-fallback",
      "type": "socks",
      "server": "100.98.29.39",
      "server_port": 2081
    }
  ]
}
```

通过 sing-box 的 `urltest` 或 `fallback` 出站类型自动切换。

---

## 已知问题

1. **Sing-box DNS** (`system-dns` type) 不能解析 `.kyb-net` 主机名——必须用静态 IP 地址（`192.168.97.3`）而非容器名连接隧道
2. **无原生 SOCKS5**——nuc8 上需要 `dante-server`，需要 root 权限安装
3. **配置同步**——`sb-config-v2` volume 的配置更改不回写宿主机 git 仓库（容器内无法访问宿主机文件系统）
4. **`glab` 403**——GitLab API 对代理有限制，Web 界面正常但 API 可能返回 403。需要 `HTTPS_PROXY` 环境变量配合 HTTP/1.1

---

## 网络安全

### kyb-net 网络隔离

隧道容器在 `kyb-net` 上监听 `0.0.0.0:2081`，意味着：
- 同网络的容器（`kyb-infra-sing-box`、`kyb-infra-boss`）可以直接连接
- 外部无法直接访问（未映射到宿主机端口）
- 仅通过 sing-box 的 `nuc8-proxy` outbound 对外暴露

### SSH 密钥安全

- SSH 私钥从宿主机只读挂载
- 容器内无法修改密钥文件
- 如果容器被攻破，攻击者可以读取密钥。但：
  - 密钥只对 nuc8 有效（目标受限）
  - nuc8 仅作为出站代理，无敏感数据

---

## 相关文档

| 文档 | 内容 |
|------|------|
| [nuc8-tunnel-deploy.md](handbook/nuc8-tunnel-deploy.md) | 部署手册 |
| [kyb-infra-boss.md](../../npc/kyb-infra-boss.md) | Infra boss 设计文档（容器拓扑） |
| [infra-boss-safety-design.md](infra-boss-safety-design.md) | 防自杀机制（含隧道 lesson） |
| [NEW-BOSS-QUICK-REF.md](NEW-BOSS-QUICK-REF.md) | 新 boss 快速上手指南 |

---

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-05-22 | 隧道跑在 kyb-infra-boss 内部（autossh PID 1） |
| 2026-05-24 | 抽出独立容器 kyb-infra-nuc8-tunnel（restart: always） |

／人◕ ‿‿ ◕人＼
