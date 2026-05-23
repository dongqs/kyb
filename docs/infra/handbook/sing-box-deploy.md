# Sing-box 代理部署手册

## 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-sing-box |
| 镜像 | kyb-sing-box:1.13.11（本地构建） |
| 端口 | 2080 (SOCKS5) |
| 网络 | kyb-net |

## Docker Run

```bash
docker run -d --name kyb-infra-sing-box \
  --network kyb-net \
  --restart always \
  -p 2080:2080 \
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
  kyb-sing-box:1.13.11
```

## 配置管理

配置目录 `~/.config/sing-box/` 是 git 仓库，挂载为只读。改配置流程：

```bash
cd ~/.config/sing-box
# 改 config.json
sing-box check -c config.json
cp config.json config.json.last-good
# 热重载
docker kill -s HUP kyb-infra-sing-box
# 验证
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://github.com
```

## 路由规则

| 目标 | 出口 | 路径 |
|------|------|------|
| github.com/google.com | Relay-JP1/HK2 等 | Shadowsocks → 国际出口 |
| leyantech.com | nuc8-proxy | SSH 隧道 → sim → Tailscale → nuc8 → 办公室 |
| 国内 IP/CDN | direct | 直连 |

## 验证

```bash
ALL_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://github.com
ALL_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://git.leyantech.com
HTTPS_PROXY=socks5://kyb-infra-sing-box:2080 glab api /user
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| `Could not resolve host: kyb-infra-sing-box` | 容器不在 kyb-net | `docker rm -f` 后加 `--network kyb-net` 重建 |
| GitLab 403 | DNS 解析到 IP 后 domain 规则不匹配 | 加 IP CIDR 规则 `120.132.11.237/32 → nuc8-proxy` |
| Google 间歇性卡死 | 死 relay (HK1 NXDOMAIN) | 从 Cursor-Auto urltest 移除 |
| glab 403 | `ALL_PROXY` 不被 Go 识别 | 用 `HTTPS_PROXY=socks5://...` |
| HTTP/2 流错误 | 多跳代理链不支持 h2 | `curl --http1.1` 或 Go 应用需配置 |
