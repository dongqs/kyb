# 火山云 ECS 交接文档 & 新人上手指南

> **机器信息：** 124.174.68.38 / 4C16G / cn-shanghai
> **用途：** sing-box 代理节点 + kyb-infra-boss 容器宿主机
> **状态：** 已上线（2026-05-24）

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
| `~/.config/sing-box/config.json` | sing-box 主配置（路由规则、出站节点） |
| `~/.config/sing-box/` | sing-box 配置目录（git 仓库，只读挂载给容器） |
| `~/.config/kyb/config.yml` | kyb 用户配置 |
| `~/.ssh/id_rsa` | 通往 nuc8 的 SSH 密钥 |
| `~/.ssh/huoshan-infra-for-boss.pem` | ECS SSH 登录密钥 |
| `/root/.ssh/` (宿主机) | SSH 密钥目录（容器只读挂载 `/root/.ssh:ro`） |

### Docker 容器一览

```bash
docker ps
```

| 容器 | 镜像 | 端口 | 重启策略 | 用途 |
|------|------|------|----------|------|
| `kyb-infra-sing-box` | `kyb-sing-box:1.13.11` | 2080:2080 | `always` | SOCKS5 代理入口 |
| `kyb-infra-nuc8-tunnel` | `kyb-base:latest` | (无映射) | `always` | SSH 隧道到 nuc8 |
| `kyb-infra-boss` | `kyb-base:latest` | (无映射) | `unless-stopped` | Claude infra boss |

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

`~/.config/sing-box/config.json` 可能包含：

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
- [ ] **sing-box 在跑？** `ps aux | grep sing-box` 或 `docker ps | grep sing-box`
- [ ] **SSH 隧道在跑？** `ps aux | grep ssh.*-D.*2081` 或 `docker ps | grep nuc8-tunnel`
- [ ] **GitHub 通？** `curl -sI --socks5-hostname 127.0.0.1:2080 https://github.com` → 期望 `200`
- [ ] **GitLab 通？** `curl -sI --socks5-hostname 127.0.0.1:2080 https://git.leyantech.com` → 期望 `302`
- [ ] **Tailscale 在线？** `tailscale status` → 能看到 nuc8 (100.98.29.39)
- [ ] **知道各个配置在哪？** `~/.config/sing-box/` / `~/.ssh/` / `~/.config/kyb/`
- [ ] **知道踩坑记录？** 读一遍第 3 节

---

## 6. kyb-infra-boss 如何在 ECS 上部署

### 背景

kyb CLI 目前还没在 ECS 上安装。kyb-infra-boss 是一个运行在 Docker 中的 Claude agent 容器，用于管理基础设施。

### 当前状态

Docker 已安装。kyb CLI 未安装。

### 临时方案：直接 Docker run

如果需要在 ECS 上部署 kyb-infra-boss，可以跳过 kyb CLI，直接用 Docker 拉 kyb-base 镜像：

```bash
# 拉取 kyb-base 镜像（需要注册表访问权限）
docker pull kyb-base:latest

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
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
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
cd ~/.config/sing-box
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

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-05-26 | 初版——ECS 交接文档 & 新人指南 |

／人◕ ‿‿ ◕人＼
