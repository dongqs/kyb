# 网络问题排查

kyb 在构建和运行时涉及大量网络操作。本文按阶段列出所有依赖网络的步骤、失败原因和解决方法。

## 构建阶段（`kyb build`）

构建镜像时 Dockerfile 按顺序执行以下网络操作。**任何一步失败则整个 build 失败**，但已成功的层会被缓存，重跑时跳过。

`kyb build` 在构建前会自动执行**前置环境检查**（pre-flight check），验证 Docker daemon、关键镜像源和下载站点的连通性。检查失败会给出明确提示，避免无谓等待。

| # | 操作 | 目标 | 重试 | 失败处理 |
|---|------|------|------|---------|
| 1 | `apt-get update` | `mirrors.aliyun.com/ubuntu` (x86) 或 `mirrors.aliyun.com/ubuntu-ports` (ARM) | 无 | build 失败 |
| 2 | `apt-get install` | 同上 | 无 | build 失败 |
| 3 | `curl https://mise.run \| sh` | `mise.run` | 5 次 × 5s 间隔 | build 失败 |
| 4 | `mise install` | node（npmmirror 镜像）/python/ruby 等，见下方详表 | **3 次 × 10s 间隔** | build 失败 |
| 5 | `npm install -g yarn` | `registry.npmmirror.com` | 无 | build 失败 |
| 6 | `pip install mig25...` | `nexus.leyantech.com` (Nexus 私有 PyPI) | 无 | **吞没**（`\|\| true`），运行时重试 |
| 7 | `curl https://code.kimi.com/install.sh \| bash` | `code.kimi.com` + uv PyPI | 无 | build 失败 |
| 8 | `pip install playwright` | `mirrors.aliyun.com/pypi` | 无 | build 失败 |
| 9 | `playwright install chromium` | `playwright.azureedge.net` | 无 | build 失败 |
| 10 | `npm install -g puppeteer` | `registry.npmmirror.com` | 无 | build 失败 |

### mise install 涉及的具体源

| 工具 | 下载源 |
|------|--------|
| node | `npmmirror.com/mirrors/node`（MISE_NODE_MIRROR_URL 设置） |
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

→ 检查宿主机能否访问外网。如果走代理，确认代理地址和端口正确。Dockerfile 末尾清除了 `ALL_PROXY`，build 期间不走代理（阿里云镜像和 Nexus 都是直连）。

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
| **`MISE_NODE_MIRROR_URL`** | Node.js 通过 `npmmirror.com` 国内镜像下载，不依赖代理 |
| **3 次重试** | `mise install` 失败后等 10s 重试，最多 3 次 |
| **cache mount** | 下载缓存持久化，重跑 build 时不重复下载相同版本 |
| **5 次重试** | mise 自身安装（`curl mise.run | sh`）最多重试 5 次 |

Node.js 使用国内镜像后，即使代理不可用也能正常安装。其他工具（python、ruby、maven）仍走代理。

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

**容器内无法访问外网**

默认容器没有设置 `ALL_PROXY`（Dockerfile 末尾清除了）。agent 需根据 CLAUDE.md 自行配置代理：

```bash
export ALL_PROXY=socks5://host.orb.internal:2080
export NO_PROXY=.leyantech.com,localhost,127.0.0.1
```

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
