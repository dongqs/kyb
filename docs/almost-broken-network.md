# 本机网络环境检查报告

> **检查原则**：只读、不修改任何配置。  
> **检查时间**：2026-05-21  
> **检查对象**：macOS 本地网络栈（多层叠加环境）

---

## 一、总体印象：六层网络堆叠

本机网络是一个**物理网 → 虚拟机 → VPN/隧道 ×9 → 系统代理** 的多层叠加架构：

```
┌─────────────────────────────────────────┐
│  应用层 (WeChat/DingTalk/浏览器/CLI...)   │
├─────────────────────────────────────────┤
│  代理层: sing-box @ 127.0.0.1:2080/2081 │  ← Wi-Fi 系统代理全部指向此处
├─────────────────────────────────────────┤
│  VPN层: Tailscale (utun6) + 其他8个隧道  │  ← utun0~8 共9个活跃隧道
├─────────────────────────────────────────┤
│  虚拟化: OrbStack/Docker (2个网桥)       │  ← bridge100, bridge101
├─────────────────────────────────────────┤
│  物理网: Wi-Fi (en0) 192.168.10.17/22   │  ← 网关 192.168.8.1
├─────────────────────────────────────────┤
│  防火墙: 已关闭                          │
└─────────────────────────────────────────┘
```

---

## 二、物理网络层

### 2.1 Wi-Fi 接口 (en0)

| 项目 | 值 |
|------|-----|
| IP 地址 | `192.168.10.17` |
| 子网掩码 | `255.255.252.0` (/22) |
| 广播地址 | `192.168.11.255` |
| 网关 | `192.168.8.1` |
| MAC 地址 | `d6:83:d6:04:c9:68`（随机化地址） |
| 物理 MAC | `bc:d0:74:f1:a2:05` |
| 状态 | active |

### 2.2 DNS 配置

macOS 真实 DNS（`scutil --dns`）：

- **主解析器**：`223.5.5.5`（阿里 DNS）— 已标记为 Reachable
- **mDNS 解析器**：`.local`、`254.169.in-addr.arpa` 等多个反向解析域 — 均标记为 Not Reachable
- **Tailscale 专用解析器**：`search.tailscale` → `tailb7fd6f.ts.net`
- **作用域解析器**：en0 接口绑定 `223.5.5.5`

> 注：`/etc/resolv.conf` 中同样配置了 `nameserver 223.5.5.5`，但 macOS 系统进程实际使用 `scutil` 管理的 DNS。

### 2.3 Hosts 文件

```
127.0.0.1       localhost
255.255.255.255 broadcasthost
::1             localhost
# 192.30.253.112 github.com
# 151.101.88.249 github.global.ssl.fastly.net
```

Hosts 文件非常干净，仅包含基础 localhost 映射。有两个被注释掉的 GitHub 旧加速地址。

### 2.4 连通性测试

| 目标 | 状态 | 延迟 |
|------|------|------|
| 网关 `192.168.8.1` | ✅ 可达 | 15~40 ms |
| DNS `223.5.5.5` | ✅ 可达 | 12~15 ms |

### 2.5 防火墙状态

```
Firewall is disabled. (State = 0)
Firewall has block all state set to disabled.
```

---

## 三、路由表

### 3.1 IPv4 路由（关键条目）

| Destination | Gateway | Flags | Interface | 说明 |
|-------------|---------|-------|-----------|------|
| `default` | `192.168.8.1` | `UGScg` | `en0` | 主默认路由 |
| `default` | `link#26` | `UCSIg` | `bridge100` | VM 桥接默认路由（被抑制 `!`） |
| `default` | `link#28` | `UCSIg` | `bridge101` | VM 桥接默认路由（被抑制 `!`） |
| `100.64/10` | `utun6` | `USc` | `utun6` | Tailscale 子网 |
| `100.100.100.100/32` | `utun6` | `USc` | `utun6` | Tailscale DNS |
| `100.104.244.99` | `100.104.244.99` | `UH` | `utun6` | Tailscale 本机节点 |
| `192.168.8/22` | `link#14` | `UCS` | `en0` | 本地局域网 |
| `192.168.138/23` | `link#26` | `UC` | `bridge100` | OrbStack VM 网段 |
| `192.168.215` | `link#28` | `UC` | `bridge101` | OrbStack VM 网段 |

### 3.2 IPv6 路由 —— 高风险区域

路由表中存在 **8 条并行的 IPv6 default 路由**，全部指向不同的 utun 接口：

```
default  fe80::%utun0  UGcIg  utun0
default  fe80::%utun1  UGcIg  utun1
default  fe80::%utun2  UGcIg  utun2
default  fe80::%utun3  UGcIg  utun3
default  fe80::%utun4  UGcIg  utun4
default  fe80::%utun5  UGcIg  utun5
default  fe80::%utun7  UGcIg  utun7
default  fe80::%utun8  UGcIg  utun8
```

当系统发送 IPv6 流量时，内核需从这 8 条路由中选择一条。若其中某些隧道对应的 VPN 已失效或配置错误，会导致 IPv6 流量间歇性超时或丢包。

### 3.3 Tailscale 专用路由

```
fd7a:115c:a1e0::/48     utun6   USc   utun6
fd7a:115c:a1e0::53      utun6   UHLS  utun6
fd7a:115c:a1e0::2c32:f463  fd7a:115c:a1e0::2c32:f463  UHL  lo0
```

---

## 四、虚拟化网络层 (OrbStack / Docker)

### 4.1 Docker 网络

```
NETWORK ID     NAME      DRIVER    SCOPE
7eebc7ea1d18   bridge    bridge    local
1a60ab08e94f   host      host      local
e13480a18cbd   none      null      local
```

### 4.2 VM 网桥

| 网桥 | 本机 IP | 网段 | 成员接口 | 状态 |
|------|---------|------|----------|------|
| `bridge100` | `192.168.139.3` | `192.168.138.0/23` | `vmenet0` | active |
| `bridge101` | `192.168.215.0` | `192.168.215.0/24` | `vmenet1` | active |

OrbStack 状态：`Running`

---

## 五、VPN / 隧道层

### 5.1 活跃隧道接口一览

本机共有 **9 个活跃的 `utun` 接口**，属于极不寻常的高密度隧道环境：

| 接口 | MTU | IP 地址 | 推测用途 |
|------|-----|---------|----------|
| `utun0` | 1500 | IPv6 only (`fe80::2590:dc3d:b838:cbd5`) | 未知隧道 |
| `utun1` | 1380 | IPv6 only (`fe80::428a:5c98:8cdd:1c87`) | 未知隧道 |
| `utun2` | 2000 | IPv6 only (`fe80::4b05:205b:efe9:49a`) | 未知隧道 |
| `utun3` | 1000 | IPv6 only (`fe80::ce81:b1c:bd2c:69e`) | 未知隧道 |
| `utun4` | 1380 | IPv6 only (`fe80::cf63:a008:d00c:7efd`) | 未知隧道 |
| `utun5` | 1380 | IPv6 only (`fe80::1bbb:bbd1:fab1:d7c6`) | 未知隧道 |
| **`utun6`** | **1280** | **100.104.244.99 + IPv6** | **Tailscale VPN** |
| `utun7` | 1380 | IPv6 only (`fe80::97c5:85a5:e5f9:6484`) | 未知隧道 |
| `utun8` | 1380 | IPv6 only (`fe80::219b:eea5:c5b4:1f92`) | 未知隧道 |

> **排查建议**：utun0~5、utun7~utun8 的 MTU 多为 1380（IPsec VPN 典型值），可能来自 iOS 网络扩展或 macOS VPN 配置文件中残留的旧连接。可通过 `lsof -i | grep utun` 或检查 **系统设置 → VPN** 来定位归属应用。

### 5.2 Tailscale 状态（2026-05-21 修复后重测）

```
2026/05/21 16:15 实测：
100.104.244.99  dongqs-mac               allothar@  macOS  -
100.113.24.32   izuf6chddvfuuw1802xb0jz  dongqs@    linux  idle
100.98.29.39    nuc8                     allothar@  linux  active; offers exit node; direct 192.168.9.219:41641
100.73.225.60   pang-s2                  allothar@  linux  -
100.124.229.78  shiwei-mac               allothar@  macOS  offline
```

- Tailscale 版本：**1.98.2**（Go 1.26.3）
- 本机节点名：`dongqs-mac`
- 已连接在线节点：**4 个**（shiwei-mac 离线）
- 节点归属：`dongqs`（dongqs-mac, sim）和 `allothar`（nuc8, pang-s2, shiwei-mac）两个用户
- `nuc8` 提供 **Exit Node** 功能，直连状态（`192.168.9.219:41641`）
- `sim` 已恢复直连，ping 走 `47.100.71.220:41641`（direct 12ms），不再经 DERP relay
- `pang-s2` 通过 sim 的 peer-relay（`47.100.71.220:40000`）连接 ~17ms，fallback DERP(tok) ~236ms
- `shiwei-mac` 离线 1h+，fallback DERP(lax)

---

## 六、代理层 (sing-box)

### 6.1 sing-box 进程

```
PID   USER     CPU  MEM      TIME      COMMAND
2267  dongqs   0.0  0.1      17:07.03  sing-box run -c config.json
```

- 配置文件：`config.json`（具体路径未显示，推测在 sing-box 工作目录）
- 运行时长：从周日 11AM 持续运行至今

### 6.2 监听端口

| 端口 | 协议 | 监听地址 | 用途 |
|------|------|----------|------|
| `2080` | TCP | `127.0.0.1` | HTTP/HTTPS 代理入口 |
| `2081` | TCP | `127.0.0.1` | SOCKS 代理入口 |

### 6.3 系统代理设置

通过 `networksetup` 查询，**Wi-Fi 服务** 的系统代理配置如下：

| 代理类型 | 启用 | 服务器 | 端口 | 认证 |
|----------|------|--------|------|------|
| Web Proxy (HTTP) | ✅ Yes | `127.0.0.1` | `2080` | No |
| Secure Web Proxy (HTTPS) | ✅ Yes | `127.0.0.1` | `2080` | No |
| SOCKS Proxy | ✅ Yes | `127.0.0.1` | `2080` | No |

> ⚠️ **关键观察**：系统代理完全依赖 sing-box。若 sing-box 进程异常退出或 config.json 配置出错，所有走系统代理的应用（浏览器、App Store 等）将瞬间断网。

### 6.4 环境变量代理

当前 Shell 环境中**未设置** `HTTP_PROXY`、`HTTPS_PROXY`、`SOCKS_PROXY` 等环境变量。

---

## 七、应用监听端口

| 端口 | 进程 | 监听地址 | 说明 |
|------|------|----------|------|
| `2080` / `2081` | sing-box | `127.0.0.1` | 代理服务 |
| `32222` | OrbStack | `127.0.0.1` / `[::1]` | OrbStack 控制通道 |
| `55773` | OrbStack | `127.0.0.1` | OrbStack 辅助通道 |
| `5432` | postgres | `127.0.0.1` / `[::1]` | PostgreSQL 数据库 |
| `8123` | clickhouse | `0.0.0.0` | ClickHouse HTTP 接口（全网监听）|
| `9000` | clickhouse | `0.0.0.0` | ClickHouse 原生协议（全网监听）|
| `9004` | clickhouse | `0.0.0.0` | ClickHouse 辅助端口（全网监听）|
| `10666` | ruby | `0.0.0.0` | Ruby 服务（全网监听）|
| `14013` / `14016` / `14019` / `14022` / `14023` | WeChat | `127.0.0.1` | 微信本地端口 |
| `8440` / `8451` | DingTalk | `127.0.0.1` | 钉钉本地端口 |
| `59769` / `49928` / `49929` | rapportd | `*` / `[::]` | Apple Handoff/Continuity |
| `7000` / `5000` | ControlCe | `*` / `[::]` | macOS 控制中心/屏幕镜像 |

> 注：ClickHouse (`8123`, `9000`, `9004`) 和 Ruby (`10666`) 监听在 `0.0.0.0`，意味着局域网内其他设备可直接访问。结合**防火墙已关闭**，存在潜在暴露风险。

---

## 八、TCP 连接状态统计

```
  82 ESTABLISHED
  68 TIME_WAIT
   4 CLOSE_WAIT
   2 FIN_WAIT_2
```

- **ESTABLISHED 82**：活跃连接数正常，包含大量通过 `127.0.0.1:2080` 的 sing-box 本地转发对（本地端口 ↔ 代理端口成对出现）
- **TIME_WAIT 68**：偏高，但属于正常范围。通常是短连接应用（如浏览器、API 调用）频繁创建/关闭连接导致，会占用本地端口资源，一般 2~4 分钟后自动释放
- **CLOSE_WAIT 4**：需关注。表示本地已收到对端 FIN 但本端未关闭 socket，若持续增长可能暗示某应用存在连接泄漏

### 8.1 典型活跃连接

- `192.168.10.17:xxxxx → 103.143.17.156:443`（2 条，境外 CDN）
- `192.168.10.17:xxxxx → 14.17.78.204:996`（多条，腾讯系服务）
- `192.168.10.17:xxxxx → 112.65.203.38:443`（多条，境内 CDN）
- `192.168.10.17:xxxxx → 223.109.146.161:443`（移动网络 CDN）
- `127.0.0.1:2080 ↔ 127.0.0.1:xxxxx`（大量成对连接，sing-box 代理转发）

---

## 九、网络接口总览

### 9.1 全部接口列表

| 接口 | 类型 | IP 地址 | 状态 |
|------|------|---------|------|
| `lo0` | Loopback | `127.0.0.1`, `::1`, `fe80::1` | UP |
| `gif0` | Generic Tunnel | 无 | 未配置 |
| `stf0` | 6to4 Tunnel | 无 | 未配置 |
| `anpi0` / `anpi1` / `anpi2` | Apple ANP | 无 | inactive |
| `en4` / `en5` / `en6` | 以太网 | 无 | inactive |
| `en1` / `en2` / `en3` | Thunderbolt 桥成员 | 无 | inactive |
| `bridge0` | Thunderbolt 桥 | 无 | inactive |
| `ap1` | Access Point | 无 | inactive |
| **`en0`** | **Wi-Fi** | **`192.168.10.17`** | **active** |
| `awdl0` | Apple Wireless Direct Link | `fe80::...` | active |
| `llw0` | Low Latency WLAN | `fe80::...` | active |
| `utun0` ~ `utun8` | 用户隧道 | 见上文 | 全部 UP |
| `vmenet0` | VM 网卡 | 无 | active |
| `vmenet1` | VM 网卡 | 无 | active |
| `bridge100` | VM 网桥 | `192.168.139.3` | active |
| `bridge101` | VM 网桥 | `192.168.215.0` | active |
| `en7` | USB 以太网 | 无 | inactive |

---

## 十、风险与观察（只记录，不修改）

| # | 风险点 | 当前影响 | 严重程度 |
|---|--------|----------|----------|
| 1 | **9 个活跃 utun 隧道** | 路由表拥挤，IPv6 有 8 条并行默认路由，可能导致 IPv6 流量路由混乱 | ⚠️ 中高 |
| 2 | **sing-box 单点依赖** | 系统代理全部指向 `127.0.0.1:2080`，sing-box 一旦崩溃，所有代理流量中断 | ⚠️ 中 |
| 3 | **单一 DNS** | 仅配置 `223.5.5.5`，无备用 DNS，阿里 DNS 故障时全系统解析失败 | ⚠️ 低 |
| 4 | **防火墙关闭** | ClickHouse、Ruby 服务监听 `0.0.0.0`，局域网内可直接访问 | ⚠️ 中（内网环境）|
| 5 | **TIME_WAIT 偏高** | 68 个 TIME_WAIT 占用本地端口，极端情况下可能导致临时端口耗尽（通常 >15000 才危险）| ℹ️ 观察 |
| 6 | **CLOSE_WAIT 4** | 需持续观察，若持续增长说明某应用未正确关闭连接 | ℹ️ 观察 |
| 7 | **Tailscale Exit Node** | `nuc8` 提供 Exit Node，若误设为全局出口，可能导致非预期流量路由 | ℹ️ 观察 |

---

## 十一、结论

本机网络是一个**典型的开发/运维工程师全栈网络栈**，多层叠加导致复杂度极高：

1. ✅ **基础物理网络正常**：Wi-Fi、网关、DNS 均可达，延迟正常。
2. ⚠️ **多层叠加**：9 个 VPN 隧道 + 系统级代理 + 2 个虚拟网桥，任何一层抖动都会影响整体体验。
3. ⚠️ **单点依赖**：系统代理完全经过 sing-box（2080 端口）。
4. ⚠️ **IPv6 路由冗余**：8 条并行 IPv6 默认路由可能导致 IPv6 偶发超时。

**当前什么都不动是对的** —— 各层组件均处于正常工作状态。若未来出现网络异常，建议优先排查方向：

1. 检查 `sing-box` 日志（`config.json` 中可能配置了日志路径）
2. 检查是否有不需要的 utun 隧道残留（系统设置 → VPN）
3. 观察 `CLOSE_WAIT` 数量是否持续增长
4. 测试 IPv6 连通性（`ping6` 或 `curl -6`）确认是否受多路由影响
