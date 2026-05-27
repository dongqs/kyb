# Proxy 配置

宿主机环境变量、NO_PROXY 设计、容器代理流。

---

## 宿主机环境变量

`~/.bash_profile` 自动配置（`lsof -i :2080` 检测到端口时设，端口不在时不设）：

```bash
if lsof -i :2080 >/dev/null 2>&1; then
  export HTTPS_PROXY=socks5://127.0.0.1:2080
  export HTTP_PROXY=socks5://127.0.0.1:2080
  export ALL_PROXY=socks5://127.0.0.1:2080
  export NO_PROXY=".deepseek.com,localhost,127.0.0.1,host.orb.internal,.local,.internal,192.168.0.0/16,100.64.0.0/10"
fi
```

| 变量 | 适用工具 |
|------|---------|
| `HTTPS_PROXY` | Go 工具（glab、gh）—— Go 的 SOCKS5 需要这个 |
| `ALL_PROXY` | curl、pip、Ruby 等 |
| `HTTP_PROXY` | 部分旧工具兼容 |

## NO_PROXY

| 条目 | 原因 |
|------|------|
| `.deepseek.com` | agent 走 deepseek API，sing-box 重启不影响通信 |
| `localhost,127.0.0.1` | 本机服务 |
| `host.orb.internal,.local,.internal` | OrbStack 内部 |
| `192.168.0.0/16` | Docker 容器网段，容器间通信直连 |
| `100.64.0.0/10` | Tailscale CGNAT（nuc8/sim 直连） |

## 容器代理流

```
kyb create:
  host kyb CLI → Kyb::Proxy.detect
                  ├── config.yml proxy 项
                  ├── env var ALL_PROXY/HTTPS_PROXY/HTTP_PROXY
                  └── 端口探测 2080/1080/7890...
                  ↓
  host_to_docker_proxy(proxy) → socks5://host.docker.internal:2080
                  ↓
  容器 env: KYB_PROXY=socks5://host.docker.internal:2080
                  ↓
  entrypoint.sh → export ALL_PROXY/HTTPS_PROXY/HTTP_PROXY="$KYB_PROXY"
```

entrypoint.sh 相关代码：

```bash
if [ -n "${KYB_PROXY:-}" ]; then
  [ -z "${ALL_PROXY:-}" ]    && export ALL_PROXY="${KYB_PROXY}"   && export all_proxy="${KYB_PROXY}"
  [ -z "${HTTPS_PROXY:-}" ]  && export HTTPS_PROXY="${KYB_PROXY}" && export https_proxy="${KYB_PROXY}"
  [ -z "${HTTP_PROXY:-}" ]   && export HTTP_PROXY="${KYB_PROXY}"  && export http_proxy="${KYB_PROXY}"
fi
```

## 已知问题

| # | 场景 | 问题 |
|---|------|------|
| 1 | sing-box 进程在但隧道坏 | proxy 工具挂起，agent 通过 `.deepseek.com` 直连不受影响 |
| 2 | 容器内 4 跳代理链 | sandbox → sing-box → boss → sim → nuc8，延迟较高 |
