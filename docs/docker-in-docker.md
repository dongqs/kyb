# kyb did — Docker-in-Docker 容器子系统

`kyb did` 是与 `kyb create/enter` 平行的独立子系统，专用于在 Docker 容器内部创建和管理沙箱容器（Docker-in-Docker）。

> **项目级 kyb 指引**：
> - [Hamilton 服务端](https://git.leyantech.com/training/hamilton/-/blob/master/.kyb.md)
> - [Hamilton-SDK 客户端](https://git.leyantech.com/training/hamilton-sdk/-/blob/main/.kyb.md)
> - [kyb 容器环境总览](docs/container.md)

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
- **生命周期绑定** — DID 容器通过 `kyb-did=<parent>` label 标记，外层 `kyb rm` 时级联清理
- **显示隔离** — DID 容器以 `did-<name>` 前缀命名，宿主 `kyb ps` 中分栏标注，DID 内只显示同类

## 命令设计

```bash
kyb did create <name>          # 创建 DID 容器
kyb did rm <name>              # 删除 DID 容器（含 volume 和子容器）
kyb did ps                     # 只列出 DID 容器
kyb ps                         # 集成显示，DID 容器单独标注类型
```

## 容器规范

| 属性 | 值 |
|------|-----|
| 命名 | `did-<name>` |
| 镜像 | `kyb-base`（与普通容器一致） |
| 网络 | 默认 bridge，IP 直连其他容器 |
| 标签 | `kyb-did=<parent-container-name>` |
| 环境变量 | `KYB_PARENT=<parent-container-name>` |
| 项目目录 | named volume `did-<name>-worktree` → `/home/dev/projects/<name>` |

## 创建流程

```
kyb did create <name>
  1. docker run -d --name did-<name>
       --label kyb-did=<parent>
       -e KYB_PARENT=<parent>
       -v did-<name>-worktree:/home/dev/projects/<name>
       -v /var/run/docker.sock:/var/run/docker.sock
       kyb-base
  2. docker cp ~/.ssh/. did-<name>:/home/dev/.ssh/
  3. docker cp ~/.gitconfig did-<name>:/home/dev/.gitconfig
  4. done — 项目目录空，agent 自行 git clone
```

## 清理流程

```
kyb did rm <name>
  1. docker rm -f did-<name>
  2. docker volume rm did-<name>-worktree
  3. docker rm -f $(docker ps -a --filter label=kyb-did=did-<name> -q)

宿主机 kyb rm <project-branch>
  → 先清理 label kyb-did=<container-name> 的所有 DID 容器
  → 再删自身容器
```

## 与 `kyb create` 对比

| 方面 | `kyb create` | `kyb did create` |
|------|-------------|-------------------|
| 使用场景 | macOS 宿主机 | DinD（容器内） |
| 项目代码 | git worktree bind mount | named volume（初始空） |
| SSH 密钥 | bind mount | `docker cp` 注入 |
| 镜像 | kyb-base | kyb-base |
| 生命周期 | 独立 | 绑定 parent 容器 |
| 网络隔离 | 前缀 `kyb-*` | 独立前缀 `did-*` |

## 项目级 kyb 指引

各项目的 `.kyb.md` 文件包含该项目的联调启动步骤和踩坑记录：

- [Hamilton 服务端](https://git.leyantech.com/training/hamilton/-/blob/master/.kyb.md)
- [Hamilton-SDK 客户端](https://git.leyantech.com/training/hamilton-sdk/-/blob/main/.kyb.md)

### 踩坑清单（跨项目通用）

| # | 问题 | 现象 | 修复 |
|---|------|------|------|
| 1 | Gradle wrapper 下载超时 | `Read timed out` | 镜像已配好（腾讯→华为云 fallback），或预下载到 `kyb-gradle-cache` |
| 2 | Gradle 锁冲突 | `Timeout waiting to lock journal cache` | entrypoint 自动清理僵尸 daemon 锁 |
| 3 | Nexus 403 | `Received status code 403` | 换网络 / 换凭据 |

### 优化效果

缓存 + 共享 volume 后，DID 容器侧联调耗时：

| 步骤 | 优化前 | 优化后 |
|------|--------|--------|
| Java 8 安装 | 5min+ 超时（需代理 + 重试） | **1m9s**（缓存命中） |
| Gradle wrapper 下载 | 10s 超时 → 手动预下载 | **0s**（`kyb-gradle-cache`） |
| Gradle 编译 + 启动 | ~4min（冷启动） | **~30s**（warm） |
| **DID 侧总耗时** | **~30min**（大部分排障） | **~2min** |

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
