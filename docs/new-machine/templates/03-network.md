# 网络层 — {new-machine-remote-hostname}

我是谁：记录 remote:ssh {new-machine-ssh-user}@{new-machine-ssh-host} 的网络状态。
我在哪：remote:~/.claude/docs/03-network.md
我要干什么：描述网络接口、DNS、端口、代理、连通性。
我不干什么：不记录硬件、OS、运行时。

## 可用工具

> 📝 操作提示：按「命令执行协议」写脚本批量查：

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-tools.sh << 'SCRIPT'
for tool in ip ss ping curl nc dig host traceroute nmap iptables tcpdump resolvectl ethtool; do
  echo -n "$tool: "
  command -v "$tool" && echo "ok" || echo "not found"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 工具 | 已装 | 用途 |
|------|------|------|
| ip / ifconfig | Y / N | 看接口和 IP |
| ss / netstat | Y / N | 看监听端口 |
| ping | Y / N | 测延迟 |
| curl / wget | Y / N | HTTP 探测 |
| nc / ncat | Y / N | TCP 端口扫描 |
| dig / nslookup | Y / N | DNS 解析 |
| host | Y / N | DNS 解析 |
| traceroute / mtr | Y / N | 路由追踪 |
| nmap | Y / N | 端口扫描（慎用）|
| iptables / nft | Y / N | 防火墙规则 |
| tcpdump | Y / N | 抓包 |
| resolvectl | Y / N | systemd DNS |
| ethtool | Y / N | 网卡信息 |

### 确认

我确认以上工具清单完整。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 当前状态

> 📝 操作提示：每个子节按协议执行。

### 接口

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-iface.sh << 'SCRIPT'
ip addr show | grep -E "^[0-9]|inet "
SCRIPT
# === local→remote === scp && ssh && commit
```

| 接口 | IP | 类型 | 备注 |
|------|----|------|------|
| lo | 127.0.0.1 | 回环 | |
| eth0 / en0 | ___.___.___.___ | 有线 / 无线 / 虚拟 | |
| wlan0 / wlp* | ___.___.___.___ | WiFi | |
| tailscale0 | 100.___.___.___ | Tailscale | |
| docker0 | 172.___.___.___ | Docker 网桥 | |
| 其他______ | ___.___.___.___ | ______ | |

### DNS

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-dns.sh << 'SCRIPT'
cat /etc/resolv.conf
hostname
SCRIPT
# === local→remote === scp && ssh && commit
```

| 项目 | 值 |
|------|-----|
| nameserver | ______ |
| 主机名 | ______ |
| MagicDNS | 可用 / 不可用 / 不知道 |

### 监听端口

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-ports.sh << 'SCRIPT'
ss -tlnp | grep -v 127.0.0.1
SCRIPT
# === local→remote === scp && ssh && commit
```

| 端口 | 进程 | 绑定的 IP | 用途推测 |
|------|------|----------|---------|
| ____ | ______ | ______ | ______ |
| ____ | ______ | ______ | ______ |

### 代理

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-proxy.sh << 'SCRIPT'
# 检查常见代理端口
for port in 1080 2080 3128 8080 8888; do
  timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/\$port" 2>/dev/null && echo "port \$port: OPEN" || true
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 地址 | 端口 | 协议 | 外网 HTTPS |
|------|------|------|-----------|
| 本机 127.0.0.1 | ____ | HTTP / SOCKS5 / 未发现 | 通 / 不通 |
| 局域网 ___.___.___.___ | ____ | HTTP / SOCKS5 / 未发现 | 通 / 不通 |
| 办公室 | ____ | HTTP / SOCKS5 / 未发现 | 通 / 不通 |

### 防火墙

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-fw.sh << 'SCRIPT'
iptables -L 2>/dev/null || echo "iptables: no perm"
nft list ruleset 2>/dev/null || echo "nft: no perm"
ufw status 2>/dev/null || echo "ufw not found"
SCRIPT
# === local→remote === scp && ssh && commit
```

| 命令 | 结果 |
|------|------|
| iptables / nft | 有规则 / 空 / 没权限 |
| ufw | active / inactive / 未装 |

### 确认

我确认以上网络信息正确，过程已记录。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 连通性矩阵

> 📝 操作提示：逐条测，每测一条就 commit。

```bash
# === local ===
cat > /tmp/kyb-{ts}-net-ping.sh << 'SCRIPT'
for target in "baidu.com" "google.com" "git.leyantech.com" "registry-1.docker.io" "100.100.100.100"; do
  result=$(curl -s -o /dev/null -w "%{http_code} %{time_total}s" --connect-timeout 5 "https://\$target" 2>&1)
  echo "\$target: \$result"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 目标 | 直连 | 走代理 | 耗时 |
|------|------|--------|------|
| 国内 (baidu.com) | 通 / 不通 | 通 / 不通 | __ms |
| 外网 (google.com) | 通 / 不通 | 通 / 不通 | __ms |
| GitLab (git.leyantech.com) | 通 / 不通 | — | __ms |
| Docker Hub | 通 / 不通 | 通 / 不通 | __ms |
| 公司 Registry | 通 / 不通 | — | __ms |
| Tailscale 节点 (100.x.x.x) | 通 / 不通 | — | __ms |

### 确认

我确认连通性测试结果正确，过程已记录。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 探索日志

| # | 时间 (精确到秒) | 操作 | 结果 | 耗时 | commit |
|---|------|------|------|------|--------|
| 1 | | 检查网络工具 | 成功/失败 缺:____ | __s | |
| 2 | | 接口和 IP | 成功/失败 | __s | |
| 3 | | 监听端口 | 成功/失败 | __s | |
| 4 | | 代理探测 | 成功/失败 | __s | |
| 5 | | 连通性矩阵 | 成功/失败 | __s | |

## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)
