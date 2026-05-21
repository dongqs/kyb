# kyb — AI agent 容器环境参考

当前运行在 kyb 管理的 Docker 容器内。本文档供 AI agent 读取，对外说明见 `README.md`。

> DID 容器系统详见 [docs/docker-in-docker.md](docker-in-docker.md)。
> 联调示例：各项目 `.kyb.md` 文件（详见 `docs/docker-in-docker.md`）。

## 容器环境

当前运行在 kyb 管理的 Docker 容器内。

### 服务

| 服务 | 访问方式 |
|------|---------|
| **PostgreSQL 16** | `postgresql://postgres:postgres@127.0.0.1:5432/postgres`，trust 认证，Asia/Shanghai |
| **ClickHouse** | `host.orb.internal:9000`，或 `clickhouse-client --host host.orb.internal` |
| **Docker** | 通过 `/var/run/docker.sock` |
| **glab** | 预配 git.leyantech.com 认证 |
| **mig25** | DSN 配在项目 `.env` |

### 网络代理

```
代理: socks5://host.orb.internal:2080
直连: .leyantech.com,git.leyantech.com,nexus.leyantech.com,localhost,127.0.0.1,host.orb.internal,.internal
```

手动启用：`export ALL_PROXY=socks5://host.orb.internal:2080`

### 宿主机挂载

| 宿主机 | 容器内 | 权限 |
|--------|-------|------|
| `~/.ssh` | `/home/dev/.ssh` | 只读 |
| `~/.gitconfig` | `/home/dev/.gitconfig` | 只读 |
| `~/.claude/settings.json` | `/home/dev/.claude-host-settings.json` | 只读 |
| `~/.claude/skills` | `/home/dev/.claude-skills-host` | 只读 |
| `~/projects` | `/home/dev/projects` | 读写 |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker API |

> **注意**：Docker socket 并非所有容器都有。`kyb create` 创建的容器有，但手动 `docker run` 创建的容器可能没有。需用 `docker ps` 确认。

### 已知问题

- **SSH zombie 进程**：每次 `ssh` 到 kyb 容器会残留 defunct sshd 进程，容器重启才清理。不影响功能，但 `ps aux` 时能看到一大堆 `<defunct>`。通常只在容器间互相 SSH 时出现（从外部 SSH 不存在此问题）。

### Git 配置

entrypoint 自动配置了 `git config --system url."git@git.leyantech.com:".insteadOf "https://git.leyantech.com/"`。
所有对 `git.leyantech.com` 的 HTTPS 访问自动走 SSH，`.gitmodules` 可安全使用 HTTPS（CI 要求）。

## 共享缓存

DID 容器共享 named volume，避免跨容器重复下载。

### Volume 一览

| Volume | 挂载路径 | 缓存内容 |
|--------|---------|---------|
| `kyb-gradle-cache` | `~/.gradle` | wrapper dists、依赖 jars |
| `kyb-maven-cache` | `~/.m2/repository` | Maven 依赖 jars |
| `kyb-mise-cache` | `~/.local/share/mise/downloads` | mise 工具链 tar.gz |
| `kyb-pip-cache` | `~/.cache/pip` | pip wheels |

### 各工具安装方式

| 工具 | 下载源 | 走镜像？ | 走代理？ | 缓存路径（具体文件） |
|------|--------|---------|---------|-------------------|
| **Java (corretto-8)** | `corretto.aws` | ✗ | ✓（更快） | `~/.local/share/mise/downloads/java/corretto-*/amazon-corretto-*-linux-aarch64.tar.gz` |
| **mise 工具链** (node/python/ruby) | GitHub/Amazon CDN | ✗ | ✓ | `~/.local/share/mise/downloads/*/` |
| **Gradle 发行版** | `mirrors.cloud.tencent.com` → `repo.huaweicloud.com` | ✓（主选） | ✗（超时） | `~/.gradle/wrapper/dists/gradle-*/hash/gradle-*-bin.zip` |
| **npm 包** | `registry.npmmirror.com` | ✓ | ✗ | `~/.npm/_cacache/` |
| **pip 包** | `mirrors.aliyun.com` | ✓ | ✗ | `~/.cache/pip/` |
| **Maven 依赖** | `nexus.leyantech.com` | ✓（内网） | ✗ | `~/.m2/repository/` |
| **Git submodules** | `git.leyantech.com` | ✗（走 SSH） | ✗ | 无缓存 |

> **说明**：
> - `kyb-mise-cache` 挂载的是 `downloads` 目录（存原始 tar.gz），非 `installs`（已解压的 JDK）。挂 `installs` 会覆盖镜像预装工具（如 GraalVM）。
> - 需在 entrypoint 设置 `mise settings set always_keep_downloads true`，否则 mise 安装后自动删除 tar.gz。
>
> **手动预填缓存**（不等 MR 合并，立即生效）：
> ```bash
> docker volume create kyb-mise-cache
> # 方式一：从已有 DID 容器的 installs 打包
> docker exec <did-container> tar -czf - -C ~/.local/share/mise/installs/java corretto-8.452.09.1 |
>   docker run --rm -i -v kyb-mise-cache:/cache alpine tar -xzf - -O > /tmp/corretto.tar.gz
>   # 上面这步只是示例，实际需要更直接的卷操作
>
> # 方式二：直接 curl 下载到 volume（走代理）
> docker run --rm -v kyb-mise-cache:/cache -e ALL_PROXY=socks5://host.orb.internal:2080 \
>   alpine sh -c "apk add --no-cache curl && \
>   mkdir -p /cache/java/corretto-8.452.09.1 && \
>   curl -sL -o /cache/java/corretto-8.452.09.1/amazon-corretto-8.452.09.1-linux-aarch64.tar.gz \
>   'https://corretto.aws/downloads/resources/8.452.09.1/amazon-corretto-8.452.09.1-linux-aarch64-jdk.tar.gz'"
> ```

## TTS（文本转语音）

宿主机 macOS 上的语音服务，端口 10666。

```bash
curl -X POST http://host.docker.internal:10666/speak \
  -H "Content-Type: application/json" -d '{"text":"你好"}'
```
