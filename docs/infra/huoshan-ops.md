# 火山云 ECS 交接文档 & 新人上手指南

> **机器信息：** 124.174.68.38 / 4C16G / cn-shanghai
> **用途：** sing-box 代理节点 + kyb-infra-boss 容器宿主机
> **状态：** 已上线 → 已切换至 Docker 容器（2026-05-26）

---

## 1. 登上去先看什么

### SSH 登录

```bash
ssh -i ~/.ssh/huoshan-infra-for-boss.pem root@124.174.68.38
```

密钥文件 `huoshan-infra-for-boss.pem` 找上一个 infra boss 要。拿到后放 `~/.ssh/`，权限设为 `600`。

### 健康检查三板斧

登录后依次确认以下三个东西都在跑：

```bash
# 1. sing-box 是否在跑
ps aux | grep sing-box

# 2. SSH 隧道是否在跑（通往 nuc8 的出站隧道）
ps aux | grep ssh.*-D.*2081

# 3. 测试网络——GitHub 通不通（走 relay 出站）
curl -sI --socks5-hostname 127.0.0.1:2080 https://github.com

# 4. 测试网络——GitLab 通不通（走 nuc8 隧道出站）
curl -sI --socks5-hostname 127.0.0.1:2080 https://git.leyantech.com

# 5. 直连测试——不走代理能不能通 GitHub（应该不通）
curl -sI --connect-timeout 5 https://github.com
```

期望结果：

| 检查项 | 期望 | 如果不对 |
|--------|------|----------|
| sing-box 进程 | 存在 | 看 [#启动 sing-box](#%E5%90%AF%E5%8A%A8-sing-box) |
| SSH 隧道进程 | 存在 | 看 [#启动 SSH 隧道](#%E5%90%AF%E5%8A%A8-ssh-%E9%9A%A7%E9%81%93) |
| GitHub (2080) | `HTTP/2 200` | sing-box relay 出站有问题 |
| GitLab (2080) | `HTTP/2 302` | SSH 隧道或 nuc8 有问题 |
| 直连 GitHub | 超时或连接失败 | 正常，被墙 |

---

## 2. 架构

### 网络拓扑

```
                          Internet
                             │
                             ▼
              ┌──────────────────────────┐
              │  火山云 ECS cn-shanghai    │
              │  124.174.68.38            │
              │  100.115.201.70 (Tail)    │
              │  4C16G / Ubuntu           │
              │                           │
              │  ┌──── kyb-net ────────┐  │
              │  │  Docker bridge net  │  │
              │  │                     │  │
              │  │  kyb-infra-sing-box │  │
              │  │  └─ :2080 (SOCKS5)  │  │
              │  │      路由规则:       │  │
              │  │      GitHub → relay │  │
              │  │      GitLab → nuc8  │  │
              │  │                     │  │
              │  │  kyb-infra-boss     │  │
              │  │  (Claude agent)     │  │
              │  │                     │  │
              │  │  kyb-infra-nuc8-    │  │
              │  │  tunnel             │  │
              │  │  └─ SSH -D 2081     │  │
              │  └─────────────────────┘  │
              │                           │
              └──────────────────────────┘
                        │ SSH -D (Tailscale)
                        ▼
              ┌──────────────────────────┐
              │  nuc8 (dongqs 家)         │
              │  100.98.29.39 (Tail)     │
              │  办公室网络可达            │
              └──────────────────────────┘
                        │
                        ▼
              ┌──────────────────────────┐
              │  办公室网络               │
              │  GitLab ✅                │
              │  其他内网服务 ✅           │
              └──────────────────────────┘

              ┌──────────────────────────┐
              │  Shadowsocks Relay       │
              │  JP1 / HK2 / SG1         │
              │  国际出站                 │
              │  GitHub / Google / ...   │
              └──────────────────────────┘
```

### 流量路径

```
# GitHub（国际流量）
curl → localhost:2080 → sing-box → relay (JP1/HK2/SG1) → GitHub ✅

# GitLab（内网流量）
curl → localhost:2080 → sing-box → nuc8-proxy outbound
     → kyb-infra-nuc8-tunnel:2081 (SSH SOCKS5)
     → Tailscale → nuc8 → 办公室网络 → GitLab ✅
```

### 所有配置文件位置

| 文件 | 用途 |
|------|------|
| `/etc/sing-box/config.json` | sing-box 主配置（路由规则、出站节点） |
| `/etc/sing-box/` | sing-box 配置目录（git 仓库，只读挂载给容器） |
| `~/.config/kyb/config.yml` | kyb 用户配置 |
| `~/.ssh/id_rsa` | 通往 nuc8 的 SSH 密钥 |
| `~/.ssh/huoshan-infra-for-boss.pem` | ECS SSH 登录密钥 |
| `/root/.ssh/` (宿主机) | SSH 密钥目录（容器只读挂载 `/root/.ssh:ro`） |

### Docker 容器一览

```bash
docker ps --filter name=kyb-infra
```

| 容器 | 镜像 | 端口 | 重启策略 | 用途 |
|------|------|------|----------|------|
| `kyb-infra-sing-box` | `kyb-sing-box:1.13.11` | 2080:2080 (host) | `always` | SOCKS5 代理入口（主服务）|
| `kyb-infra-nuc8-tunnel` | `kyb-nuc8-tunnel:latest` | 2081 (kyb-net) | `always` | SSH 隧道到 nuc8 |

**注意：** 2026-05-26 已从原生进程切到 Docker 容器。原生的 sing-box 和 SSH 隧道已停。systemd 原生服务已 disable（防止重启冲突）。

详情分别见：

- [sing-box 部署手册](handbook/sing-box-deploy.md)
- [nuc8 隧道架构](./nuc8-tunnel-architecture.md)
- [infra-boss 安全设计](./infra-boss-safety-design.md)

---

## 3. 踩坑记录

### 坑 1：不要用 Tailscale exit node

Tailscale exit node 功能会把所有流量通过 Tailscale 网络路由出去。ECS 上**不要开**。原因：

- 一开 exit node，当前 SSH 连接直接断掉（因为 SSH 本身走 Tailscale 路由出去了）
- ECS 没有 IPMI / 带外管理，只能用火山云控制台的 **VNC** 救回来
- VNC 体验极差——复制粘贴不行，网络延迟高

**结论：** Tailscale 只在 ECS 上用于直连 nuc8（通过 Tailscale IP 100.98.29.39），不做 exit node。

### 坑 2：sing-box 依赖 SSH 隧道

sing-box 的 `nuc8-proxy` outbound 指向 `kyb-infra-nuc8-tunnel:2081`。如果隧道容器挂了：

- GitLab 流量全部中断
- sing-box 本身还在跑，GitHub 等国际流量不受影响
- 重启隧道后自动恢复，不需要重启 sing-box

**监控建议：** 定期 curl GitLab 检查隧道是否存活，不要只看 sing-box 进程。

### 坑 3：ECS 在 cn-shanghai，直连 GitHub 被墙

这是最根本的限制。ECS 位于国内阿里云 region，直连 GitHub/GitLab 等境外服务：

- 超时（TCP 连接被阻断）
- 间歇性丢包
- DNS 污染

**任何时候在 ECS 上操作 GitHub 相关的事情，都走 `ALL_PROXY=socks5://127.0.0.1:2080`。**

包括但不限于：

```bash
# git clone/push/pull
ALL_PROXY=socks5://127.0.0.1:2080 git clone https://github.com/...

# curl API
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://github.com

# npm/pip/go get 等包管理
ALL_PROXY=socks5://127.0.0.1:2080 npm install
```

### 坑 4：shadowsocks relay 从 ECS 连不上

Shadowsocks 中继节点（JP1、HK2、SG1 等）是境外服务器。ECS 从 cn-shanghai 直连这些节点：

- 部分节点的 IP 可能被墙或 QoS
- 连接不稳定，经常超时
- 所以才有 SSH 隧道到 nuc8 的方案——nuc8 在 dongqs 家，办公室网络出墙路径更稳定

**sing-box 配置里 relay 节点如果连不上，优先怀疑被墙，而不是配置错了。**

### 坑 5：部署前先检查 apt sources

apt sources 配置的是 Ubuntu 官方源，在国内可能很慢。如果 `apt update` 慢或者报错：

```bash
# 检查当前源
cat /etc/apt/sources.list

# 如果慢，换阿里云镜像
sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
apt update
```

**不要**直接覆盖 sources.list——先备份：`cp /etc/apt/sources.list /etc/apt/sources.list.bak`

---

## 4. 安全事项

### 4.1 SSH 密钥保护

文件 `/root/.ssh/id_rsa` 是通往 nuc8（dongqs 家的机器）的 SSH 私钥。拿到这个密钥的人可以：

- SSH 登录 nuc8
- 通过 nuc8 访问办公室网络
- 通过 nuc8 访问 GitLab

**保护措施：**

- 权限必须 `600`：`chmod 600 /root/.ssh/id_rsa`
- 不要复制到不安全的地方
- 不要在日志里打印密钥内容
- 如果怀疑泄露，立即联系 dongqs 从 nuc8 的 `authorized_keys` 中移除

### 4.2 sing-box 配置中的敏感信息

`/etc/sing-box/config.json` 可能包含：

- Shadowsocks 密码 / 加密方式
- 中继节点地址

**不要**把这些信息写在明文文档里。如果需要记录，用环境变量或者单独的加密文件。

### 4.3 火山云 Access Key

`.env` 文件中的 `VOLC_ACCESS_KEY` / `VOLC_SECRET_KEY` 是子账号权限：

- 权限范围应当最小化（仅限 ECS 操作）
- 泄露后攻击者可以创建/销毁 ECS 实例
- 定期轮换

### 4.4 防火墙规则

ECS 安全组已开放端口：

| 端口 | 用途 | 来源 |
|------|------|------|
| 22 | SSH | 指定 IP 或跳板机 |
| 2080 | SOCKS5 代理 | 仅内部使用 |

**不要额外开放不必要的端口。** sing-box 监听在 Docker network（kyb-net）内部，不暴露到宿主机 `0.0.0.0`，只有 2080 映射到宿主机。

### 4.5 容器安全

- 隧道容器以只读模式挂载 SSH 密钥：`-v /root/.ssh:/root/.ssh:ro`
- 容器内进程以非 root 运行（SSH 命令本身）
- sing-box 配置目录也是只读挂载

---

## 5. 新人 Checklist

第一次接手时，逐项确认：

- [ ] **SSH 能连上？** `ssh -i ~/.ssh/huoshan-infra-for-boss.pem root@124.174.68.38`
- [ ] **sing-box 在跑？** `docker ps --filter name=kyb-infra-sing-box`
- [ ] **SSH 隧道在跑？** `docker ps --filter name=kyb-infra-nuc8-tunnel`
- [ ] **GitHub 通？** `curl -sI --socks5-hostname 127.0.0.1:2080 https://github.com` → 期望 `200`
- [ ] **GitLab 通？** `curl -sI --socks5-hostname 127.0.0.1:2080 https://git.leyantech.com` → 期望 `302`
- [ ] **Tailscale 在线？** `tailscale status` → 能看到 nuc8 (100.98.29.39)
- [ ] **Docker 容器在？** `docker ps --filter name=kyb-infra` → 两个容器 Up
- [ ] **Docker 代理通？** `docker run --rm --network kyb-net alpine:latest sh -c 'getent hosts kyb-infra-nuc8-tunnel'`
- [ ] **systemd 启用？** `systemctl is-enabled kyb-sing-box.service kyb-nuc8-tunnel.service` → enabled
- [ ] **知道各个配置在哪？** `/etc/sing-box/` / `~/.ssh/` / `~/.config/kyb/`
- [ ] **知道踩坑记录？** 读一遍第 3 节

**新增双备后的额外确认：**
- [ ] **Docker sing-box 独立配置** → `/etc/sing-box/config.docker.json`（nuc8-tunnel 指向容器 IP）
- [ ] **构建文件** → `/root/docker-build/` 目录下
- [ ] **Docker daemon 代理** → `/etc/systemd/system/docker.service.d/proxy.conf`
- [ ] **切换计划** → 见附录"双备容器化"

---

## 6. kyb-infra-boss 如何在 ECS 上部署

### 背景

kyb CLI 目前还没在 ECS 上安装。kyb-infra-boss 是一个运行在 Docker 中的 Claude agent 容器，用于管理基础设施。

### 当前状态

Docker 已安装，双备容器已运行。kyb CLI 未安装。

**已有容器：**
- `kyb-infra-sing-box` — sing-box SOCKS5 代理
- `kyb-infra-nuc8-tunnel` — SSH 隧道到 nuc8

**已有镜像：**
- `kyb-sing-box:1.13.11`（108MB，本地构建）
- `kyb-nuc8-tunnel:latest`（21.2MB，本地构建）

### 临时方案：直接 Docker run

如果需要在 ECS 上部署 kyb-infra-boss，可以跳过 kyb CLI，直接用 Docker 拉 kyb-base 镜像：

> **注意：** ECS 无法直连 Docker Hub，需要通过代理拉取（已在系统级配置）。但 `kyb-base` 镜像较大（~8GB），建议从本地 registry 拉取或构建。

```bash
# 拉取 kyb-base 镜像（需要注册表访问权限）
ALL_PROXY=socks5://127.0.0.1:2080 docker pull kyb-base:latest

# 创建 kyb 网络（如果还没有）
docker network create kyb-net

# 运行 boss 容器
docker run -d --name kyb-infra-boss \
  --network kyb-net \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root/.ssh:/root/.ssh:ro \
  -v /root/.config:/root/.config:ro \
  kyb-base:latest \
  sleep infinity
```

### 安装 kyb CLI（可选）

从项目仓库安装：

```bash
# 需要先 clone 仓库（走代理）
ALL_PROXY=socks5://127.0.0.1:2080 git clone https://github.com/your-org/kyb.git /opt/kyb

# 安装依赖
cd /opt/kyb
ALL_PROXY=socks5://127.0.0.1:2080 bundle install

# 创建 symlink
ln -s /opt/kyb/bin/kyb /usr/local/bin/kyb
```

注意：ECS 在 cn-shanghai，`git clone` 和 `bundle install` 都必须走代理（`ALL_PROXY=socks5://127.0.0.1:2080`）。

---

## 7. 运维操作参考

### 启动 sing-box

```bash
docker start kyb-infra-sing-box
```

如果容器不存在，重建：

```bash
docker run -d --name kyb-infra-sing-box \
  --network kyb-net \
  --restart always \
  -p 2080:2080 \
  -v /etc/sing-box/:/etc/sing-box/:ro \
  kyb-sing-box:1.13.11
```

### 启动 SSH 隧道

```bash
docker start kyb-infra-nuc8-tunnel
```

如果容器不存在，重建：

```bash
docker run -d --name kyb-infra-nuc8-tunnel \
  --restart always \
  --network kyb-net \
  --memory 64m \
  -v /root/.ssh:/root/.ssh:ro \
  kyb-base:latest \
  ssh -o ControlMaster=no \
      -o StrictHostKeyChecking=no \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -D 0.0.0.0:2081 \
      -N root@100.98.29.39
```

注意：容器内 SSH 的目标用户从 `dongqs` 换成 `root`，因为 ECS 上 `/root/.ssh/id_rsa` 对应的是 nuc8 的 root 用户。如果 nuc8 上配置的是其他用户，改回来。

### 热重载 sing-box 配置

```bash
# 改完配置后检查语法
cd /etc/sing-box
sing-box check -c config.json

# 热重载
docker kill -s HUP kyb-infra-sing-box

# 验证
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://github.com
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://git.leyantech.com
```

### 查看日志

```bash
docker logs kyb-infra-sing-box --tail 50
docker logs kyb-infra-nuc8-tunnel --tail 20
```

---

## 相关文档

| 文档 | 内容 |
|------|------|
| [sing-box 部署手册](handbook/sing-box-deploy.md) | sing-box 配置、路由规则 |
| [nuc8 隧道架构](./nuc8-tunnel-architecture.md) | SSH 隧道容器详细设计 |
| [infra-boss 安全设计](./infra-boss-safety-design.md) | 防自杀机制、容器拓扑 |
| [NEW-BOSS-QUICK-REF.md](./NEW-BOSS-QUICK-REF.md) | 新 boss 快速上手指南 |
| [火山云路线图](./huoshan-roadmap.md) | 长期规划 |
| [火种状态](./huoshan-state.json) | 火山云 ECS 状态快照 |

---

## 附录：双备容器化（2026-05-26）

继原生进程部署后，新增 Docker 容器化双备层。老进程不动，新容器并行运行。

### 新增架构

```
老（原生进程，不动）              新（Docker 容器，热备）
─────────────────              ─────────────────
sing-box (PID 6551) :2080      kyb-infra-sing-box :2080 (kyb-net)
SSH 隧道 (PID 6453) :2081      kyb-infra-nuc8-tunnel :2081 (kyb-net)
  无保活/无自启                    systemd enable + restart: always
```

### Docker 容器

| 容器 | 镜像 | 网络 | 重启策略 | 备注 |
|------|------|------|----------|------|
| `kyb-infra-sing-box` | `kyb-sing-box:1.13.11` | kyb-net | `always` | musl 版（Alpine）|
| `kyb-infra-nuc8-tunnel` | `kyb-nuc8-tunnel:latest` | kyb-net | `always` | 内存 64m |

### Docker 镜像

| 镜像 | 大小 | 基础镜像 | 构建位置 |
|------|------|----------|----------|
| `kyb-sing-box:1.13.11` | 108MB | alpine:latest | `/root/docker-build/sing-box/` |
| `kyb-nuc8-tunnel:latest` | 21.2MB | alpine:latest | `/root/docker-build/nuc8-tunnel/` |

**注意：** Docker sing-box 使用 musl 版二进制（Alpine 兼容）。构建时需走代理下载：
```bash
cd /root/docker-build/sing-box
docker build --network host \
  --build-arg HTTP_PROXY=http://127.0.0.1:2080 \
  --build-arg HTTPS_PROXY=http://127.0.0.1:2080 \
  -t kyb-sing-box:1.13.11 .
```

### 配置

Docker sing-box 使用独立配置文件，nuc8-tunnel 出站指向 Docker 容器 IP（而非 127.0.0.1）：

```
原生: /etc/sing-box/config.json         → nuc8-tunnel: 127.0.0.1:2081
Docker: /etc/sing-box/config.docker.json → nuc8-tunnel: 172.18.0.2:2081
```

**注意：** 容器重启后 IP 可能变化。如果重建了 nuc8-tunnel 容器，需要同步更新 `config.docker.json` 并重启 sing-box 容器：
```bash
# 获取新 IP
TUNNEL_IP=$(docker inspect kyb-infra-nuc8-tunnel | python3 -c \
  'import sys,json; print(json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]["kyb-net"]["IPAddress"])')

# 更新配置
sed -i "s/\"server\": \"[0-9.]*\"/\"server\": \"$TUNNEL_IP\"/" /etc/sing-box/config.docker.json

# 重建 sing-box 容器（配置只读挂载，不能热重载）
docker rm -f kyb-infra-sing-box
docker run -d --name kyb-infra-sing-box \
  --restart always --network kyb-net \
  -v /etc/sing-box/config.docker.json:/etc/sing-box/config.json:ro \
  kyb-sing-box:1.13.11
```

### Systemd 服务

| 服务名 | 作用 | 状态 |
|--------|------|------|
| `kyb-sing-box.service` | sing-box 进程保活 | enabled（未激活，不冲突）|
| `kyb-nuc8-tunnel.service` | SSH 隧道保活 | enabled（未激活，不冲突）|

服务文件在 `/etc/systemd/system/`，启用但未启动（避免与原生进程端口冲突）。
重启机器后会自动接管。

如果未来切到 Docker-only（停掉原生进程后），可直接启动：
```bash
systemctl start kyb-sing-box.service     # 启动原生 sing-box
systemctl start kyb-nuc8-tunnel.service  # 启动原生 SSH 隧道
```
或者直接 Docker 方案（推荐）。

### Docker daemon 代理配置

Docker daemon 通过 systemd drop-in 配置了代理，用于拉取镜像：
```
/etc/systemd/system/docker.service.d/proxy.conf
```
内容：HTTPS_PROXY=socks5://127.0.0.1:2080
**如果 Docker daemon 重启后代理丢失：** 检查此文件是否存在，`systemctl daemon-reload && systemctl restart docker`。

### 构建上下文

所有 Docker 构建文件在 `/root/docker-build/`：
```
/root/docker-build/
├── sing-box/
│   ├── Dockerfile
│   ├── sing-box          # glibc 版（原生 Ubuntu 用）
│   ├── sing-box-musl     # musl 版（Alpine 容器用）
│   └── Dockerfile.test   # 测试用（已删）
└── nuc8-tunnel/
    └── Dockerfile
```

### Dcker 验证命令

```bash
# 查看容器
docker ps --filter name=kyb-infra

# 测试 Docker sing-box 代理
docker run --rm --network kyb-net alpine:latest sh -c "
  wget -q -O /dev/null --timeout=5 \
    --header 'Host: github.com' \
    https://github.com
"

# 验证 nuc8 隧道 Docker DNS 解析
docker run --rm --network kyb-net alpine:latest \
  sh -c 'getent hosts kyb-infra-nuc8-tunnel'

# 容器间端口连通性
docker run --rm --network kyb-net alpine:latest \
  sh -c 'nc -zv -w3 kyb-infra-nuc8-tunnel 2081'
```

### 切换计划（未来）

从原生进程切换到 Docker 容器的步骤：

```bash
# 1. 停原生进程
kill $(pgrep -f '^sing-box run') $(pgrep -f 'ssh.*-D.*2081')

# 2. 删掉重建 sing-box 容器，加端口映射
docker rm -f kyb-infra-sing-box
docker run -d --name kyb-infra-sing-box \
  --restart always --network kyb-net \
  -p 2080:2080 \
  -v /etc/sing-box/config.docker.json:/etc/sing-box/config.json:ro \
  kyb-sing-box:1.13.11

# 3. 确认 nuc8-tunnel 已经有端口映射（不需要，内部通信）
# 4. 验证
curl -sI --socks5-hostname 127.0.0.1:2080 https://github.com
curl -sI --socks5-hostname 127.0.0.1:2080 https://git.leyantech.com

# 5. 可选：启用 systemd 服务作为兜底
systemctl start kyb-sing-box.service
systemctl start kyb-nuc8-tunnel.service
```

---

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-05-26 | 初版——ECS 交接文档 & 新人指南 |
| 2026-05-26 | 附录：双备容器化——Docker 容器 + systemd 保活 |

／人◕ ‿‿ ◕人＼
