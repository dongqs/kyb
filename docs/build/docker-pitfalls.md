# Docker Build 踩坑记录

本文记录 `kyb build` 过程中遇到的 Docker 构建问题和解决方案，供后续维护参考。

## 1. `--mount=type=cache` 权限问题

### 症状

```dockerfile
# 预先创建缓存目录并 chown（在普通 RUN 中）
RUN mkdir -p /home/dev/.local/share/mise/downloads && \
    sudo chown -R dev:dev /home/dev/.local/share/mise

# 之后在 cache mount 的 RUN 中安装工具
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    mise install node@25
```

报错：

```
mise ERROR Failed to install core:node@25:
  failed create_dir_all: ~/.local/share/mise/downloads/node/25.9.0:
  Permission denied (os error 13)
```

### 根因

`--mount=type=cache` 在每次 RUN 时创建一个**全新的临时 mount**，覆盖目标路径。即使外层镜像层已经 `chown` 过，cache mount 内部的目录仍然归 root 所有。

### 解决

每个使用 cache mount 的 RUN 命令内，在访问目录之前先 `chown`：

```dockerfile
RUN --mount=type=cache,target=/home/dev/.local/share/mise/downloads \
    sudo chown -R dev:dev /home/dev/.local/share/mise && \
    for i in 1 2 3; do /home/dev/.local/bin/mise install node@25 && break; sleep 5; done
```

外层单独的 `RUN mkdir + chown` 层可以保留（加速首次目录初始化），但不能替代 cache mount 内的 chown。

## 2. Build Context 不一致（容器内开发时的陷阱）

### 症状

在容器内修改 `~/projects/kyb/Dockerfile` 后运行 `kyb build`，构建始终用旧缓存：

```
docker build 输出全是 CACHED
改动没生效
```

### 根因

`kyb build` 的构建上下文由 `config.yml` 的 `base.image` 决定，通常是宿主机路径 `/Users/dongqs/github/kyb`。容器内开发时：

| 路径 | 用途 | 修改是否影响 build |
|------|------|-------------------|
| `~/projects/kyb/Dockerfile` | 容器 worktree | ❌ 不影响 build |
| `/Users/dongqs/github/kyb/Dockerfile` | 宿主机 repo（build context） | ✅ 决定构建结果 |

### 解决

每次改完 Dockerfile 需要同步到宿主机路径再 build：

```bash
# 手动同步
cp ~/projects/kyb/Dockerfile /Users/dongqs/github/kyb/Dockerfile

# 或者在宿主机直接编辑
# 或者在容器内提交到 git 后，在宿主机 pull
```

或者设置 `kyb_repo` 指向宿主机路径，容器内可直接访问。

## 3. MISE_NODE_MIRROR_URL 与版本同步

### 症状

配置了 npmmirror 镜像，但 node v25.9.0 下载报 404：

```
HTTP status client error (404 Not Found) for url
(https://cdn.npmmirror.com/binaries/v25.9.0/node-v25.9.0.tar.gz)
```

### 根因

npm 镜像（npmmirror）同步官方源有延迟。Node.js 25 是最新大版本，npmmirror 上缺少对应 tarball。mise 构造的下载 URL 会基于 `MISE_NODE_MIRROR_URL` 拼接，但镜像站可能缺少最新版本的二进制文件。

### 解决

去掉 `MISE_NODE_MIRROR_URL`，让 node 通过 build proxy 直接从官方源下载。如果确定镜像站已同步新版，可以重新启用。

## 4. mise install 拆碎为独立层

### 动机

原 Dockerfile 用一个 `RUN` 装所有 mise 工具：

```dockerfile
RUN mise install   # 所有7个工具
```

问题：
- 任何工具版本变化 → 全部重装（10-15分钟）
- 网络波动单工具失败 → 全部重试
- 无法从日志判断哪个工具出问题

### 方案

拆为 7 个独立 `RUN`，按稳定性排序：

```dockerfile
RUN mise install node@25       # 最稳定，几乎不变
RUN mise install python@3.10   # 稳定
RUN mise install ruby@3.3      # 稳定
RUN mise install maven@3.9     # 中等
RUN mise install glab@1.92     # 中等
RUN mise install clickhouse@26 # 中等
RUN mise install claude-code@2 # 最易变，放最后
```

### cache mount 共享

所有工具共享 `target=/home/dev/.local/share/mise/downloads` 缓存挂载点。尽管每个 RUN 层独立，cache mount 的缓存目录在宿主机上持久化，所以已下载的 tarball 不会重复下载。

### 开销

每层额外开销约 0.3s（mise 启动 + Docker layer commit），7 层总计约 2s。换来的收益：
- 单工具版本变化只重建 1 层（约 30s vs 15min）
- 单工具下载失败只重试该层
- 构建日志一目了然

## 5. 代理统一管理

### 历史

旧方案在 Dockerfile 中硬编码 `ALL_PROXY`：

```dockerfile
ENV ALL_PROXY=socks5://host.orb.internal:2080
```

新方案使用 `--build-arg` 传入：

```dockerfile
ARG BUILD_ALL_PROXY=
ENV ALL_PROXY=${BUILD_ALL_PROXY}
```

`kyb build` 自动检测代理后传参：

```bash
docker build --build-arg BUILD_ALL_PROXY=socks5://... .
```

### 检测链

1. `config.yml` → `base.proxy`（用户显式配置）
2. 环境变量 → `ALL_PROXY` / `HTTPS_PROXY` / `HTTP_PROXY`
3. 端口探测 → `host.orb.internal:2080` / `localhost:1080` / `127.0.0.1:7890` ...

详见 `lib/kyb/proxy.rb`。
