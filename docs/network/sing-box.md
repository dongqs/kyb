# Sing-box 网络拓扑

宿主机层、Docker 基础设施、sing-box 路由规则、Tailscale 组网。

---

## 物理层

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS 宿主机 (dongqs-mac)                                       │
│  Tailscale: 100.104.244.99                                       │
│  Wi-Fi en0: 192.168.1.x/24  →  网关 192.168.1.1  →  上海移动    │
│  DNS: 223.5.5.5 (Aliyun)                                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │  OrbStack (Docker 引擎)  │
              │  端口 2080 → 容器映射     │
              └────────────┬────────────┘
                           │
              ┌────────────┴──────────────────────┐
              │  kyb-net (192.168.97.0/24)        │
              │                                   │
              │  kyb-infra-sing-box               │  ← 代理入口
              │  (192.168.97.2:2080)              │
              │                                   │
              │  kyb-infra-boss                   │  ← SSH 隧道管理
              │  (192.168.97.3:2081)              │
              │                                   │
              │  PG14/15/16/17, Redis, Kafka,     │
              │  ClickHouse, Grafana              │
              │                                   │
              │  kyb-* sandbox 容器(2026-05-23 起)│  ← docker run --network kyb-net
              │  通过 Docker DNS 可访问所有 infra   │
              └───────────────────────────────────┘
```

## 路由规则（按优先级）

```
入站:
  mixed-in  :2080  ← 主代理
  mixed-us  :2081  ← 备用代理

顺序 条件                        出站          说明
 1  .local                       direct        本地域名
 2  10.23.0.0/16                 nuc8-proxy    公司内网网段
 3  RFC1918/CGNAT                direct        127/10/172.16/192.168/100.64
 4  hijack-dns                   hijack        DNS 劫持
 5  ads                          reject        广告拦截
 6  cursor.sh/com                Cursor-Auto   Cursor IDE
 7  ai-extra                     Relay-US2     AI 额外站点
 8  ai-sites                     Relay-JP1     AI 站点
 9  google                       Cursor-Auto
10  proxy-sites                  Relay-JP1     非 CN 代理站点
11  private-ip                   direct        兜底私网
12  120.132.11.237/32            nuc8-proxy    GitLab IP
    +120.132.22.40/32
13  leyantech.com                nuc8-proxy    公司域名
14  cn-ip                        direct        CN IP 段
15  cn-sites                     direct        CN 站点

出站:
  Relay-HK2/3/4   shadowsocks → monolink.net  香港
  Relay-JP1/2     shadowsocks → monolink.net  日本
  Relay-US1/2     shadowsocks → monolink.net  美国
  Cursor-Auto     urltest (多路选优)
  nuc8-proxy      SOCKS5 → 192.168.97.3:2081
  direct          直连
```

## 流量路径

### 国际/AI 站点

```
App / Container
  │ ALL_PROXY=socks5://host.docker.internal:2080
  ▼
host.docker.internal:2080 → OrbStack → kyb-infra-sing-box
  │ 路由：无匹配 → 兜底
  ▼
Relay-JP1/US1 → monolink.net 出口
```

### 公司内网（GitLab、Nexus）

```
App / Container
  │ ALL_PROXY=socks5://host.docker.internal:2080
  ▼
host.docker.internal:2080 → OrbStack → kyb-infra-sing-box
  │ 路由：leyantech.com / 120.132.11.237 → nuc8-proxy
  ▼
SOCKS5 → kyb-infra-boss:2081
  │ SSH 隧道 (autossh, Tailscale 直连 nuc8)
  ▼
nuc8 (100.98.29.39:2081) ← Tailscale
  │ sing-box on nuc8
  ▼
办公室 → GitLab (120.132.11.237)
```

> GitLab HTTPS 必须走 3 跳代理链。SSH (`git@`) 直连不依赖 proxy。
> 2026-05 更新：SSH 隧道不再经 sim 跳转（`-J sim`），改为 Tailscale 直连 nuc8。

### 中国站点

```
App / Container
  │ ALL_PROXY=socks5://host.docker.internal:2080
  ▼
host.docker.internal:2080 → OrbStack → kyb-infra-sing-box
  │ 路由：cn-sites / cn-ip → direct
  ▼
直连 → 上海移动出口
```

## Tailscale

```
dongqs-mac     100.104.244.99   本机
sim            100.113.24.32    阿里云 ECS（跳板机）
nuc8           100.98.29.39     办公室（出口节点）
pang-s2        100.73.225.60    Linux
shiwei-mac     100.124.229.78   macOS
```

nuc8 提供 exit node，公司内网流量经 SSH 隧道（Tailscale 直连）→ nuc8 转发。
