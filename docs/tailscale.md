# Tailscale — kyb 容器访问内网机器

kyb 容器默认在 OrbStack 内网（`192.168.215.0/24`），但部分内网机器走 Tailscale（`100.x.y.z`）。本容器内可以直连 Tailscale IP，无需额外配置。

## 已知 Tailscale 节点

| 主机名 | Tailscale IP | 用户 | 状态 | 备注 |
|--------|-------------|------|------|------|
| nuc8 | `100.98.29.39` | `allothar` | ✅ 在线 | NUC 小主机，SSH 可达，提供 Exit Node |
| sim | `100.113.24.32` | `dongqs` | ✅ 在线 | 阿里云 ECS，已开放 UDP，已启用 relay port 40000 |
| pang-s2 | `100.73.225.60` | `allothar` | ✅ 在线 | allothar 的 Linux 机器，走 peer-relay 经 sim |
| shiwei-mac | `100.124.229.78` | `allothar` | ❌ 离线 | allothar 的 macOS，1h+ 未上线（2026-05-21） |

## SSH 配置

`~/.ssh/config` 中已有相关配置：

```
Host nuc8 nuc8-direct
  User dongqs

Host nuc8-direct
  HostName 192.168.9.219

Host nuc8
  HostName 100.98.29.39
  ControlMaster auto
  ControlPath /tmp/ssh-mux-%r@%h:%p
  ControlPersist 10m
  ServerAliveInterval 30
  ServerAliveCountMax 3
  Compression yes
```

直接连接：

```bash
ssh -o StrictHostKeyChecking=no nuc8
```

或指定 Tailscale IP：

```bash
ssh -o StrictHostKeyChecking=no dongqs@100.98.29.39
```

> `~/.ssh` 在容器内只读挂载，known_hosts 写不了，详见 [ssh.md](ssh.md#关键约束ssh-是只读挂载)。建议宿主机 SSH config 直接加 `StrictHostKeyChecking no`。

## 网络拓扑

```
Tailscale 网络 (100.x.y.z)
  ├── dongqs-mac (100.104.244.99)      ─── macOS，宿主机
  │     └── kyb 容器 (192.168.215.x)
  ├── sim (100.113.24.32)               ─── 阿里云 ECS，公网 IP 47.100.71.220
  │     └── relay port 40000            ─── 自定义中继
  └── nuc8 (100.98.29.39)               ─── 家宽 NUC，内网 192.168.9.219
```

kyb 容器不需要安装 Tailscale 客户端——宿主机 Tailscale 路由会处理 `100.x.y.z` 的流量。

## 在 kyb 容器内操作 nuc8

```bash
# 执行单条命令
ssh -o StrictHostKeyChecking=no nuc8 "ls -la /home/"

# 复制文件
scp some-file nuc8:~

# 持久会话（需要 TTY，需在宿主机执行）
# ssh nuc8
```

## 添加新节点

如果有新的 Tailscale 机器需要从容器访问，在 `~/.ssh/config` 添加类似配置：

```
Host <name>
  HostName 100.x.y.z
  User <user>
```

## 防火墙 / 直连优化

Tailscale 节点之间默认通过 DERP relay 中转，延迟较高。要建立 P2P 直连需要 UDP 端口放行。

### 端口说明

| 端口 | 协议 | 用途 | 建议 |
|------|------|------|------|
| `41641/udp` | WireGuard | Tailscale 直连通信 | **必须开放** |
| `40000/udp` | Peer Relay | 自定义中继（可选） | 开放更好 |

### 各节点配置

**sim**（已完成）：
1. 阿里云安全组已开放 `41641/udp` 和 `40000/udp`
2. 已启用 Peer Relay：
   ```bash
   sudo tailscale set --relay-server-port=40000
   ```

## 已知坑：Tailscale + 阿里云 ECS 的 100.64.0.0/10 冲突

### 现象

在阿里云 ECS 上启用 Tailscale 后，可能出现：
- DNS 完全坏死（`Could not resolve host`）
- `ping 100.100.2.136` 100% 丢包
- `curl http://100.100.100.200/latest/meta-data/` 超时
- `apt-get update` 连不上阿里云镜像源

### 根因

Tailscale 的 `ts-input` iptables 链有一条防 spoofing 规则：

```
DROP  !tailscale0 *  100.64.0.0/10  ->  0.0.0.0/0
```

这条规则丢弃所有非 tailscale0 接口来的 100.64.0.0/10 流量。

但阿里云 ECS 的内部基础设施也使用 100.64.0.0/10 的子段：
- `100.100.2.136/138` → DHCP 分配的内网 DNS
- `100.100.100.200` → 元数据服务（metadata）
- `100.100.2.148` → `mirrors.cloud.aliyuncs.com`

因此 DNS 响应、ICMP echo reply、HTTP 响应从 eth0 返回时，源 IP 命中 100.64.0.0/10，被 `ts-input` 误杀。

### 修复

在 `INPUT` 链的 `ts-input` jump **之前**插入白名单（不要加在 `ts-input` 链里，会被 tailscaled 重写）：

```bash
sudo iptables -I INPUT 1 -i eth0 -s 100.100.0.0/16 -j ACCEPT
```

并持久化：

```bash
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

> 放行整个 `100.100.0.0/16` 而不是单个 IP，因为阿里云内部服务可能分布在多个 IP 上（如镜像源用 `100.100.2.148`，不在 `100.100.2.136/31` 内）。

**nuc8**（路由器端口转发）：
- UDP `41641` → `192.168.9.219`
- 这样 nuc8 也能被直连，一劳永逸

### 验证直连

```bash
tailscale status        # 看所有节点在线状态
tailscale ping --c 3 <ip>  # 看连接方式是 direct 还是 relay
```

## 连通性矩阵

当前各节点间的连接状态，**从宿主机 macOS 实测**（2026-05-21，Tailscale 1.98.2）：

| ↓源→目标 | sim | nuc8 | dongqs-mac | pang-s2 |
|---------|-----|------|-----------|---------|
| **sim** | — | **peer-relay** 11ms | **peer-relay** 12ms | ? |
| **nuc8** | **direct** 10ms | — | **direct** 8ms | ? |
| **dongqs-mac** | **direct** 12ms | **direct** 11ms | — | **peer-relay** 17ms① |
| **pang-s2** | ? | ? | **peer-relay** 17ms① | — |

> ① pang-s2 通过 sim 的 peer-relay（`47.100.71.220:40000`）连接到 dongqs-mac，延迟 17ms。无直连路径时，走 DERP(tok) 236ms。

**更新说明**：sim 的 UDP 端口（`41641`）放行后，dongqs-mac → sim 已从 relay 400ms 降至 direct 12ms。nuc8 一直能直连两边。

**剩余待优化**（低优先级）：nuc8 在家宽 CGNAT 后，无法被 sim 直连。目前走 peer-relay 11ms 已足够。

---

## 宿主机网络环境备注

本机 macOS 宿主机网络极度复杂，Tailscale 只是多层叠加中的一环。完整拓扑见 [almost-broken-network.md](almost-broken-network.md)。与本容器相关的关键观察：

- **9 个活跃 utun 隧道**（utun0~utun8），Tailscale 只占其中一个（utun6）
- **8 条并行 IPv6 default 路由** 指向 utun0~5、utun7、utun8，可能导致 IPv6 流量路由混乱
- **IPv6 路由表拥挤** 时，Tailscale IPv6 (`fd7a:115c:a1e0::/48`) 可能受其他隧道干扰
- 如果容器内或宿主机出现间歇性网络超时，建议优先检查是否有不需要的 utun 隧道残留（**系统设置 → VPN**）

> 当前各层组件均正常工作，无需修改。详见 [almost-broken-network.md](almost-broken-network.md) 完整报告。

## 经验教训

### 1. 先诊断再动手

本来的问题是"Tailscale 不能直连"，实际原因是 nuc8 在家宽 CGNAT 后面没有 UDP 入口。**不是配错了，是物理网络限制**。正确顺序：

```
发现问题 → 诊断（ping/tailscale ping/tailscale status）→ 定位瓶颈 → 修复
```

差点直接去改 sim 的 iptables/安全组，要不是网络炸了，根本不知道真正的问题是 nuc8 没有端口转发。

### 2. 阿里云 ECS 跑 Tailscale 必踩的坑

**100.64.0.0/10 冲突**（见上节）是阿里云 ECS × Tailscale 的经典问题。装完 Tailscale 后 DNS 和元数据服务一定会挂，iptables 白名单必须先配好。

### 3. 公网 ECS 不一定能直连

有公网 IP（sim 47.100.71.220）的机器可以被别人直连，但它自己不一定能直连别人——如果目标在家宽 CGNAT 后面。所以：
- **出向直连**取决于对方有没有 UDP 入口
- **入向直连**取决于自己有没有开放 UDP 端口

### 4. Peer Relay 比 DERP 重要

阿里云 ECS 的带宽通常比 DERP(hkg) 好得多。配一个 relay port（40000）后，即使没有 P2P 直连，延迟也只要 11ms（vs DERP 的 400ms）。

### 5. 在容器里改网络配置要非常小心

`~/.ssh` 只读、Docker socket 不一定有、装 SDK 可能改依赖、改 iptables 可能断连。**需要在宿主机或直接在目标机器上操作的，别在容器里绕**。
