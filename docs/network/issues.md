# 网络问题排查

> **网络拓扑**：[`sing-box.md`](sing-box.md) | **Proxy 配置**：[`proxy.md`](proxy.md)

kyb 在构建和运行时涉及大量网络操作。本文按阶段列出所有依赖网络的步骤、失败原因和解决方法。

## 构建阶段（`kyb build`）

构建镜像时 Dockerfile 按顺序执行以下网络操作。**任何一步失败则整个 build 失败**，但已成功的层会被缓存，重跑时跳过。

`kyb build` 在构建前会自动执行**前置环境检查**（pre-flight check），验证 Docker daemon、关键镜像源和下载站点的连通性。检查失败会给出明确提示，避免无谓等待。

| # | 操作 | 目标 | 重试 | 失败处理 |
|---|------|------|------|---------|
| 1 | `apt-get update` | `mirrors.aliyun.com/ubuntu` (x86) 或 `mirrors.aliyun.com/ubuntu-ports` (ARM) | 无 | build 失败 |
| 2 | `apt-get install` | 同上 | 无 | build 失败 |
| 3 | `curl https://mise.run \| sh` | `mise.run` | 5 次 × 5s 间隔 | build 失败 |
| 4 | `mise install`（7 独立层） | 见下方详表，每工具独立下载 | 每工具 **3 次 × 5s 间隔** | build 失败 |
| 5 | `npm install -g yarn` | `registry.npmmirror.com` | 无 | build 失败 |
| 6 | `pip install mig25...` | `nexus.leyantech.com` (Nexus 私有 PyPI) | 无 | **吞没**（`\|\| true`），运行时重试 |
| 7 | `curl https://code.kimi.com/install.sh \| bash` | `code.kimi.com` + uv PyPI | 无 | build 失败 |
| 8 | `pip install playwright` | `mirrors.aliyun.com/pypi` | 无 | build 失败 |
| 9 | `playwright install chromium` | `playwright.azureedge.net` | 无 | build 失败 |
| 10 | `npm install -g puppeteer` | `registry.npmmirror.com` | 无 | build 失败 |

### mise install 涉及的具体源

| 工具 | 下载源 |
|------|--------|
| node | `nodejs.org/dist`（通过代理） |
| python | `python.org/ftp` |
| ruby | `cache.ruby-lang.org` |
| maven | `dlcdn.apache.org/maven` |
| glab | `gitlab.com/gitlab-org/cli/releases` |
| clickhouse | `clickhouse.com` / `packages.clickhouse.com` |
| claude-code | `registry.npmjs.org/@anthropic-ai/claude-code` |

### 常见 build 失败原因

**网络连接失败**

```
curl: (7) Failed to connect to mise.run port 443
```

→ 运行 `kyb preflight` 检查各端点连通性。`kyb build` 会自动检测宿主机代理（通过 `config.yml` → 环境变量 → 端口探测），通过 `--build-arg BUILD_ALL_PROXY` 传入 Docker 构建过程。构建完成后镜像内不保留代理配置（入口点在运行时按需配置）。

**镜像源不可用**

```
Err:1 http://mirrors.aliyun.com/ubuntu noble InRelease
  Could not connect to mirrors.aliyun.com:443
```

→ 阿里云镜像偶尔抽风。等待后重跑 `kyb build` 即可，已成功的层走缓存。

**apt-get 签名错误**

```
W: GPG error: ... The following signatures couldn't be verified
```

→ 宿主机时间不准导致 GPG 签名验证失败。检查系统时间。

### 解决方式

```bash
# 重试 build（缓存已成功层，只跑失败的层）
kyb build

# 如果怀疑 DNS / 网络问题，先验证
curl -sS https://hub.docker.com > /dev/null && echo "docker OK" || echo "docker FAIL"
curl -sS https://mirrors.aliyun.com > /dev/null && echo "mirror OK" || echo "mirror FAIL"

# 不使用镜像，直接连官方源（较慢）
# 编辑 Dockerfile，注释掉 Aliyun mirror 那行然后重跑
```

### mise 网络优化说明

Dockerfile 已内置以下措施提高 mise install 的健壮性：

| 措施 | 说明 |
|------|------|
| **独立分层** | 7 个工具各自独立 RUN 层，一工具失败不连累其他，版本变化只重建对应层 |
| **3 次重试 × 5s** | 每工具下载失败后自动重试 3 次 |
| **cache mount** | 下载缓存持久化，重跑 build 时不重复下载 |
| **5 次重试** | mise 自身安装（`curl mise.run \| sh`）最多重试 5 次 |

工具安装顺序（按稳定性排列，最稳定的先装）：

```
node@25 → python@3.10 → ruby@3.3 → maven@3.9 → glab@1.92 → clickhouse@26 → claude-code@2
```

越靠前的工具层越不容易被后续版本变化 invalidate。

---

## 运行时阶段（`kyb create` / 容器启动）

entrypoint.sh 在容器首次启动时执行以下网络操作。**这些失败不影响容器启动**，大多被 `|| true` 吞没，进入容器后可手动重试。

| # | 操作 | 目标 | 失败影响 |
|---|------|------|---------|
| 1 | `pip install mig25...` | Nexus 私有 PyPI | 容器内无 `mig25` 命令，手动重装即可 |
| 2 | `yarn install` | npmmirror | 项目依赖未安装，手动 `yarn install` |
| 3 | `npm install` | npmmirror | 项目依赖未安装，手动 `npm install` |
| 4 | `bundle install` | `gems.ruby-china.com` | Ruby 依赖未安装，手动 `bundle install` |
| 5 | `curl ... api/v4/user` (glab 配置) | `git.leyantech.com` | glab 用户名默认为 `user`，不影响使用 |

### 运行时网络问题

**~~容器内无法访问外网~~（2026-05-23 已修复）**

~~默认容器没有设置 `ALL_PROXY`（Dockerfile 末尾清除了），agent 需根据 CLAUDE.md 自行配置代理。~~

> **现已自动配置**：entrypoint.sh 从 `KYB_PROXY`（由 `kyb create` 传入）导出 `ALL_PROXY`、`HTTPS_PROXY`、`HTTP_PROXY`，容器内工具开箱即用走代理。
>
> 如果手动测试代理连通性，参考值：
> ```bash
> export ALL_PROXY=socks5://host.docker.internal:2080
> export NO_PROXY=.deepseek.com,localhost,127.0.0.1,host.orb.internal,.local,.internal,192.168.0.0/16,100.64.0.0/10
> ```
>
> `NO_PROXY` 排除了 `.deepseek.com`，确保重启 sing-box 时不中断 agent（Claude Code）与 deepseek API 的通信。

**apt-get/npm/pip 走不了国内镜像**

容器内有预配置的镜像源（阿里云、npmmirror、ruby-china），这些在镜像构建时已写入，运行时不受宿主机网络影响。如果特定镜像不可达：

```bash
# 查看当前镜像配置
cat ~/.npmrc        # npm
cat ~/.pip/pip.conf # pip
cat ~/.gemrc        # gem
```

**ClickHouse 连接失败**

ClickHouse 运行在宿主机，容器内通过 `host.orb.internal:9000` 访问。如果连不上：

- 检查宿主机 ClickHouse 是否运行
- 确认 OrbStack DNS 正常：`ping host.orb.internal`

**PostgreSQL 启动失败**

PostgreSQL 在容器内由 entrypoint.sh 启动。如果连不上：

```bash
pg_ctlcluster 16 main status   # 检查状态
pg_ctlcluster 16 main start    # 手动启动
```


---

## TLS / SSL 客户端指纹问题（运行时）

### 现象

某些 HTTPS 端点（如 `status.deepseek.com`）在容器内用 `curl` 或 `openssl s_client` 访问时，TCP 三次握手成功，但 TLS Client Hello 发出后直接被对端关闭连接：

```bash
curl https://status.deepseek.com/feed.rss
# → SSL_ERROR_SYSCALL / unexpected eof while reading / read 0 bytes
```

但同一时刻：
- `api.deepseek.com` → 正常返回 401
- `chat.deepseek.com` → 正常返回 429
- 宿主机上某些工具可以访问，某些不行

### 根因

不是 DNS、路由、MTU、代理、证书、SNI、ALPN 或 TLS 版本问题。经过跨平台交叉验证，确认为**服务器端 WAF/负载均衡对特定 TLS Client Hello 指纹做了黑名单**。

**失败的 SSL/TLS 库**：
| 库 | 环境 | 结果 |
|----|------|------|
| OpenSSL 3.0.13 | Ubuntu 24.04 系统（容器内 curl/python3/openssl） | ❌ 失败 |
| LibreSSL 3.3.6 | macOS 系统 curl | ❌ 失败 |

**成功的 SSL/TLS 库**：
| 库 | 环境 | 结果 |
|----|------|------|
| OpenSSL 3.2.0 | 宿主机 Ruby (rbenv) | ✅ 成功 |
| OpenSSL 3.5.6 | 容器内 mise Python 3.10.20 / uv Python 3.13.13 | ✅ 成功 |
| OpenSSL 3.6.2 | 宿主机 pyenv Python 3.10.13 | ✅ 成功 |

LibreSSL 3.3.6 和 OpenSSL 3.0.13 虽然代码库完全不同，但它们的 **TLS Client Hello 指纹/扩展特征相似**，共同命中了服务器端 WAF 的黑名单。OpenSSL 3.2+ 的指纹不同，可以绕过。

> 这不是 OpenSSL 3.0.13 本身的 bug，而是服务器端对"旧版 TLS 客户端指纹"的封锁。因此升级基础镜像中的 OpenSSL 或使用新版工具链是有效 workaround。

### 对 kyb 的影响

- `lib/kyb/check.rb` 使用 Ruby `Net::HTTP`，若 Ruby 链接的是系统 OpenSSL 3.0.13（Ubuntu 24.04 默认），检查 `status.deepseek.com` 等受 WAF 保护的端点时可能报 SSL 错误
- 当前容器内**无系统 Ruby**，宿主机 Ruby (OpenSSL 3.2.0) 不受影响
- `kyb preflight` 中使用的是 `curl`（容器内链接 OpenSSL 3.0.13），若检查列表中包含被 WAF 封锁的端点，会误报失败

### Workaround

**方案 A：使用 mise/uv 安装的新版 Python（推荐）**

```bash
# 容器内
/home/dev/.local/share/mise/installs/python/3.10.20/bin/python3.10 -c \
  "import urllib.request; print(urllib.request.urlopen('https://...').status)"
```

**方案 B：宿主机工具**

宿主机 pyenv Python (OpenSSL 3.6.2) 或 Homebrew wget (OpenSSL 3.x) 均可正常访问。

**方案 C：升级容器基础镜像 OpenSSL**

在 Dockerfile 或基础镜像中把 `libssl3` 升级到 3.2+ / 3.5+，使系统 curl/openssl 恢复正常。需要修改 Dockerfile 并重建镜像。

> 这不是通用网络故障，只影响特定端点（目前仅确认 `status.deepseek.com` 及其同 CDN 的站点）。大部分 API 端点不受影响。

### 诊断速查

```bash
# 快速判断是否是 SSL 指纹问题（而非网络/代理问题）
# 1. 同一域名，curl 失败但 Python (mise) 成功 → 大概率是 SSL 指纹
# 2. 同一域名，curl 失败但 wget (Homebrew/OpenSSL) 成功 → 确认是 SSL 指纹
# 3. api.deepseek.com 正常但 status.deepseek.com 失败 → 不是通用 deepseek 封锁

# 容器内确认 SSL 库版本
curl --version | head -1        # 看链接的 OpenSSL 版本
python3 -c "import ssl; print(ssl.OPENSSL_VERSION)"   # 系统 Python
/home/dev/.local/share/mise/installs/python/*/bin/python3* -c "import ssl; print(ssl.OPENSSL_VERSION)"  # mise Python
```
