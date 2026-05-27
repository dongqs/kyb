# nuc8 SSH 隧道 + 办公室网络手册

## 拓扑

```
用户 → sing-box:2080 → nuc8-proxy 出站
  ↓
kyb-infra-boss:2081 (SSH 隧道监听)
  ↓ SSH -L
sim (47.100.71.220, 阿里云 ECS)
  ↓ Tailscale (100.113.24.32)
nuc8 (100.98.29.39:2080, SOCKS5)
  ↓
办公室网络 → GitLab (120.132.11.237)
```

## SSH 隧道

```bash
ssh -o ExitOnForwardFailure=yes -f -N \
  -L 0.0.0.0:2081:100.98.29.39:2080 sim
```

## 隧道管理

```bash
# 检查
ps aux | grep "ssh.*2081"
ss -tlnp | grep 2081

# 杀掉
kill $(lsof -ti :2081)

# 重建
# 同上 SSH 命令
```

## 验证 GitLab

```bash
HTTPS_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://git.leyantech.com
# → 302 (login page) = 正常
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| GitLab 连不上 | SSH 隧道断了 | 检查 `ps aux | grep 2081`，重建隧道 |
| Docker 拉取极慢 | sim 只有 3Mbps 小水管 | 走 relay 而非 nuc8 路径，或提前缓存镜像 |
| 端口占用 | 隧道进程残留 | `kill $(lsof -ti :2081)` |
| nuc8 不可达 | Tailscale 断开（宿主机未运行） | 上 sim 检查 `tailscale status` |
| glab 403 | API 层限制 | Web 界面能进就行，API 需 HTTP/1.1 |
