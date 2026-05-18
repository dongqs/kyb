# kyb did — Docker-in-Docker 容器子系统

`kyb did` 是与 `kyb create/enter` 平行的独立子系统，专用于在 Docker 容器内部创建和管理沙箱容器（Docker-in-Docker）。

## 背景

kyb 现有 `kyb create` 架构基于 git worktree + bind mount 创建沙箱，这在宿主机（macOS）上工作正常。但当你 **在 kyb 容器内再跑 kyb**（Docker-in-Docker），这套架构失效了：

- Git worktree 路径在容器 overlay 文件系统上，宿主机 Docker daemon 看不到 → mount 无效
- `~/.ssh`、`~/.gitconfig` 等通过 virtiofs 挂载的路径同样对宿主机不可见
- 层层修复（Bind mount → named volume → docker cp）只是打补丁，DinD 需要不同的操作模式

**`kyb did` 从零开始为 DinD 设计**，不做 worktree，不 bind mount，用最简方式搞定容器初始状态。

## 设计目标

- **不依赖 git worktree** — DID 容器项目目录是空的，agent 自行 `git clone`
- **SSH 密钥通过 `docker cp` 注入** — 不服 bind mount，避免 virtiofs 不可见问题
- **多实例并行不冲突** — 每个 DID 容器独立的 project volume
- **生命周期绑定** — DID 容器通过 `did_parent=<parent>` label 标记，外层 `kyb rm` 时级联清理
- **显示隔离** — `kyb did ps` 默认只显示同 scope 的 sibling，`--all` 显示全部

## 命令设计

```bash
kyb did create <name>          # 创建 DID 容器
kyb did rm <name>              # 删除 DID 容器（含 volume 和子容器）
kyb did ps [--all]             # 列出 DID 容器（--all: 全部，默认 sibling）
kyb ps                         # 集成显示，DID 容器单独标注类型
```

## 容器规范

| 属性 | 值 |
|------|-----|
| 命名 | `did-<project>-<branch>-<name>` |
| 镜像 | `kyb-base`（与普通容器一致） |
| 网络 | 默认 bridge，IP 直连其他容器 |
| 标签 | `did_parent=<parent-container-name>`（仅此一 label） |
| 环境变量 | `KYB_PROJECT=<name>`, `KYB_BRANCH=<branch>`, `KYB_PARENT=<parent>`, `KYB_DID=<name>` |
| 项目目录 | named volume `did-<project>-<branch>-<name>-worktree` → `/home/dev/projects/<name>` |

## 行为约束

### 禁止嵌套

DID 容器内 `KYB_DID` 已设置，执行 `kyb did create` 直接报错退出。DID 不允许二级嵌套。

### 执行环境

`kyb did create` 必须在 kyb 容器内运行（需要 `KYB_PROJECT` + `KYB_BRANCH`），宿主机上运行报错。

### 冲突检测

创建前遍历所有 Docker 容器名（不限 `did-*` 前缀），发现重名则报错。

### 显示隔离

`kyb did ps` 默认按当前 scope 过滤：

| 位置 | `kyb did ps`（默认） | `kyb did ps --all` |
|------|-------------------|-------------------|
| 宿主机 | 所有 `did-*` | 所有 `did-*` |
| kyb 容器内 | 只显示自己名下的 children（`did_parent=<self>`） | 所有 `did-*` |
| DID 容器内 | 只显示同 parent 的 sibling（`did_parent=<parent>`） | 所有 `did-*` |

## 创建流程

```
kyb did create <name>
  1. 检查 KYB_DID 已设 → 报错（禁止嵌套）
  2. 检查 KYB_PROJECT + KYB_BRANCH → 报错（需在容器内运行）
  3. 全局查容器名冲突 → 报错
  4. docker run -d \
       --name did-<project>-<branch>-<name> \
       --label did_parent=<parent> \
       -e KYB_PROJECT=<name> \
       -e KYB_BRANCH=<branch> \
       -e KYB_PARENT=<parent> \
       -e KYB_DID=<name> \
       -v did-<project>-<branch>-<name>-worktree:/home/dev/projects/<name> \
       -v /var/run/docker.sock:/var/run/docker.sock \
       kyb-base
  5. docker cp ~/.ssh/. did-<project>-<branch>-<name>:/home/dev/.ssh/
  6. docker cp ~/.gitconfig did-<project>-<branch>-<name>:/home/dev/.gitconfig
  7. done — 项目目录空，agent 自行 git clone
```

## 启动性能

`kyb did create` 实测启动时间，从最初的 ~17s 优化至 ~1.8s（`kyb-base` 镜像已缓存的情况）。

### 优化历程

| 版本 | 耗时 | 原因 |
|------|------|------|
| 原始（settings.json timeout） | ~17s | DID 容器无 host settings mount，`settings.json` 永不生成，wait 循环硬等 15s 超时 |
| + `/tmp/kyb-ready` sentinel | 8.3s | entrypoint 末尾打 sentinel，entrypoint 完成即退出 wait |
| + 去掉 PG 自启动 | 6.8s | DID 容器不需要 PostgreSQL |
| + 条件 chown + pip 去 `-U` | 1.8s | UID 无变化时跳过 chown，pip 不联网检查升级 |

### 大头分解

entrypoint 初始化阶段耗时分布（首次 DID 容器启动，镜像已缓存）：

| 步骤 | 耗时 | 说明 |
|------|------|------|
| UID/GID 调整 + chown | ~2s → ~0s | 条件跳过（默认 UID 不变） |
| pip install (mig25, requests) | ~2.3s → ~0s | 去 `-U` 后包已安装则跳过 |
| Docker socket GID 匹配 | 0.8s | groupadd + usermod，不改 |
| settings.json / onboarding | 0.2s | jq 操作，不改 |
| glab / CLAUDE.md / 项目 setup | ~0s | 已有配置则跳过 |
| `docker run` + Ruby 收尾 (cp/chown) | 1.4s | 容器启动 + 文件注入 |
| **总计** | **~1.8s** | |

### 优化内容

- **条件 chown**：`uid_changed`/`gid_changed` 追踪，UID/GID 无变化时跳过 `chown -R dev:dev /home/dev`（遍历共享 volume 最耗时）
- **PG 不自启动**：DID 容器不需要 PostgreSQL，需要时手动 `pg_ctlcluster 16 main start`
- **pip 去 `-U`**：包版本在镜像构建时固定，`-U` 每次联网检查升级属多余开销

## 清理流程

```
kyb did rm <name>
  1. docker rm -f $(docker ps -a --filter label=did_parent=did-<project>-<branch>-<name> -q)
  2. docker rm -f did-<project>-<branch>-<name>
  3. docker volume rm did-<project>-<branch>-<name>-worktree

宿主机 kyb rm <project-branch>
  → docker ps -a --filter label=did_parent=<container> 查 DID 子容器 → 级联删除
  → 再删自身容器
```

## 与 `kyb create` 对比

| 方面 | `kyb create` | `kyb did create` |
|------|-------------|-------------------|
| 使用场景 | macOS 宿主机 | DinD（容器内） |
| 项目代码 | git worktree bind mount | named volume（初始空） |
| SSH 密钥 | bind mount | `docker cp` 注入 |
| 镜像 | kyb-base | kyb-base |
| 生命周期 | 独立 | 绑定 parent 容器，禁止嵌套 |
| 环境变量 | `KYB_PROJECT`, `KYB_BRANCH` | `KYB_PROJECT`, `KYB_BRANCH`, `KYB_PARENT`, `KYB_DID` |
| 标签 | `kyb=true` | `kyb=true`, `did_parent=<parent>` |

## 环境变量解析

| 变量 | 用途 | 设置于 |
|------|------|--------|
| `KYB_PROJECT=<name>` | 项目短名，用于项目目录路径 | 所有容器 |
| `KYB_BRANCH=<branch>` | 当前分支 | 所有容器（`kyb create` 起就注入） |
| `KYB_PARENT=<parent>` | 父容器全名，用于 sibling 查找和级联清理 | 仅 DID 容器 |
| `KYB_DID=<name>` | 标记此容器是 DID 子容器，值=短名 | 仅 DID 容器 |

`did_parent` label 仅设于 DID 容器，值=父容器全名。kyb 容器没有此 label。

## 联调示例：Hamilton + Hamilton-SDK

以 Hamilton（Quarkus 服务）和 Hamilton-SDK（Java 8 客户端）的联合调试为例，演示 DID 容器的实际使用流程。

### 准备工作

确保 `kyb-base` 镜像已构建（`kyb build`），两个项目的 MR 已合并到 master。

### 启动 Hamilton 服务

```bash
# 1. 克隆项目（外层宿主）
cd ~/projects && git clone git@git.leyantech.com:training/hamilton.git

# 2. 准备数据库（需要先启动 PostgreSQL）
sudo pg_ctlcluster 16 main start
createdb hamilton_dev
createdb hamilton_test

# 3. 初始化子模块（注意：用 SSH，不要用 HTTPS）
cd hamilton
git submodule update --init --recursive
# 如果报 HTTPS 认证错误：
git config submodule.Norland.url git@git.leyantech.com:base-service/Norland.git
git submodule sync && git submodule update --init Norland

# 4. 数据库迁移 + 代码生成
cp env.sample .env
MIG25_DSN=postgresql://postgres:postgres@127.0.0.1:5432/hamilton_dev mig25 upgrade
MIG25_DSN=postgresql://postgres:postgres@127.0.0.1:5432/hamilton_test mig25 upgrade
mig25-codegen generate     # ← 写入 build/generated/，clean 后需重跑

# 5. 启动 Quarkus dev mode（端口 8081，全接口监听）
QUARKUS_HTTP_HOST=0.0.0.0 \
QUARKUS_HTTP_PORT=8081 \
QUARKUS_DEV_SERVICES_ENABLED=false \
QUARKUS_DATASOURCE_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/hamilton_dev \
QUARKUS_DATASOURCE_USERNAME=postgres \
QUARKUS_DATASOURCE_PASSWORD= \
QUARKUS_OTEL_ENABLED=false \
JINGDONG_SERVICE_APP_KEY=placeholder \
JINGDONG_SERVICE_APP_SECRET=placeholder \
DOUYIN_SERVICE_DY_ATX_APP_KEY=placeholder \
DOUYIN_SERVICE_DY_ATX_APP_SECRET=placeholder \
DOUYIN_SERVICE_DY_BOT_APP_KEY=placeholder \
DOUYIN_SERVICE_DY_BOT_APP_SECRET=placeholder \
./gradlew quarkusDev --no-daemon --no-configuration-cache
```

> **坑：port 8080 被占**：Quarkus 默认 8080，上一个进程退出后端口可能被残留进程占用。
> 用 `lsof -ti :8080 | xargs kill -9` 清理，或指定不同端口（`QUARKUS_HTTP_PORT=8081`）。
>
> **坑：127.0.0.1 绑定**：Quarkus 默认绑定 localhost，其他容器无法访问。必须设置 `QUARKUS_HTTP_HOST=0.0.0.0`。

### 启动 Hamilton-SDK Demo（DID 容器）

```bash
# 6. 查看 Hamilton 容器 IP
docker inspect kyb-hamilton-kyb --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
# → 192.168.215.16

# 7. 创建 DID 容器（假设在 kyb-hamilton-kyb 内）
kyb did create hamilton-sdk
# → 容器名: did-hamilton-kyb-hamilton-sdk

# 8. 把 SDK 项目代码复制进去
docker cp ~/projects/hamilton-sdk/. did-hamilton-kyb-hamilton-sdk:/home/dev/projects/hamilton-sdk/
docker exec did-hamilton-kyb-hamilton-sdk sudo chown -R dev:dev /home/dev/projects/hamilton-sdk

# 9. 安装 Java 8（SDK demo 需要 Java 8 toolchain）
docker exec -u dev did-hamilton-kyb-hamilton-sdk bash -c '
  eval "$(~/.local/bin/mise activate bash)"
  mise install java@corretto-8.452.09.1
  JAVA8_HOME=$HOME/.local/share/mise/installs/java/corretto-8.452.09.1
  mkdir -p ~/.gradle
  printf "org.gradle.java.installations.paths=%s\n" "$JAVA8_HOME" >> ~/.gradle/gradle.properties
'

# 10. 启动 demo server（指向 Hamilton 容器）
docker exec -d -u dev did-hamilton-kyb-hamilton-sdk bash -c "
  eval \"\$(~/.local/bin/mise activate bash)\"
  cd /home/dev/projects/hamilton-sdk
  HAMILTON_SERVICE_URL=http://192.168.215.16:8081/api \
  ./gradlew :demo:run --no-daemon --no-configuration-cache > /tmp/demo.log 2>&1
"

# 11. 验证链路
docker exec did-hamilton-kyb-hamilton-sdk bash -c '
  curl -s "http://localhost:8080/sdk/sellers/1/trades/1001/seller_orders?fields=tid,status,title"
'
# → [{...数据...}]  通！
```

> **坑：Java 8 缺失**：sdk demo 需要 Java 8 toolchain，而 `kyb-base` 只预装了 Java 21。
> DID 容器内需要通过 `mise install java@corretto-8` 手动安装。
> 将来可以考虑加入 kyb 共享 volume 的 toolchain 缓存。

### 踩坑清单

| # | 问题 | 现象 | 修复 |
|---|------|------|------|
| 1 | Git submodule HTTPS 认证 | `fatal: could not read Username` | 改用 SSH URL |
| 2 | `mig25-codegen` 输出被 clean 清除 | `Unresolved reference 'generated'` | 重跑 `mig25-codegen generate` |
| 3 | Dev mode 缺 platform key | Quarkus 启动即挂 | `application.properties` 加 placeholder（已合） |
| 4 | Quarkus 只绑 127.0.0.1 | 其他容器连不上 | `quarkus.http.host=0.0.0.0`（已合） |
| 5 | Quarkus port 8080 冲突 | `Port 8080 seems to be in use` | `lsof -ti :8080 \| xargs kill -9` |
| 6 | Gradle 锁争夺 | `Timeout waiting to lock journal cache` | 共享 volume 避免并发（已实现） |
| 7 | Java 8 缺失 | Gradle: `Cannot find Java installation matching 8` | `mise install java@corretto-8` |
| 8 | Nexus 403 | `Received status code 403` | 换网络 / 换凭据 |

## 已知问题

### Nexus 403 Forbidden：特定项目依赖不可用

**现象**：容器内 Gradle 构建下载依赖时返回 `HTTP 403`，通常是 `readonlyuser` 凭据对某些仓库组没有读权限。

**原因**：kyb 基础镜像内置的 Nexus 凭据 `readonlyuser:mimashishiliuwei` 只能访问 `maven-public` 组内的大部分公共依赖。部分项目（如 `hamilton-sdk` 的 `leyan-proto` 依赖）可能不在该组的允许列表中，需要不同的网络环境或凭据。

**排查方法**：
```bash
# 测试凭据是否有效
curl -s -u "readonlyuser:mimashishiliuwei" -o /dev/null -w "%{http_code}" \
  "https://nexus.leyantech.com/repository/maven-public/com/leyantech/leyan/leyan-proto/1.42.49/leyan-proto-1.42.49.jar"
# 返回 200 = OK, 401/403 = 凭据或权限问题
```

**解决方案**（按优先级）：
1. 切换到可访问的**网络环境**（某些内网 IP 段/公司网络对 `readonlyuser` 的 ACL 不完整）
2. 联系运维将项目依赖加入 `maven-public` 组的可读列表
3. 在容器内通过 `ORG_GRADLE_PROJECT_nexusUser` / `ORG_GRADLE_PROJECT_nexusPassword` 覆盖为有权限的凭据

## 后续待实现

- SSH 密钥变更同步（外层容器更新 `~/.ssh` 后自动同步到 DID 容器）
- 配置化 DID 容器初始化脚本
- 端口映射支持 (`kyb did create <name> --ports ...`)
- 自定义环境变量注入
