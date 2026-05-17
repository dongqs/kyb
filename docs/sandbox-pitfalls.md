# kyb sandbox 实现踩坑记录

实现 `kyb sandbox`（宿主机直跑 Claude Code sandbox）过程中遇到的核心问题和解决方案。

## 1. `--sandbox` CLI flag 不存在

**现象**：`claude --sandbox` 报 `unknown option`。

**原因**：Claude Code 沙箱不是通过 CLI flag 启用的，而是通过 `.claude/settings.json` 中的 `sandbox.enabled: true` 配置。项目级 settings 自动被发现并合并到全局设置。

**解决**：在 worktree 下写 `.claude/settings.json`：
```json
{
  "sandbox": { "enabled": true },
  "permissions": { "allow": ["*"] }
}
```

## 2. `--dangerously-skip-permissions` 弹出确认警告

**现象**：每次启动弹 "WARNING: Claude Code running in Bypass Permissions mode"，需要手动确认。

**原因**：Claude Code 对 bypass permissions 模式有安全提示，需要显式跳过。

**解决**：在 settings.json 中加 `"skipDangerousModePermissionPrompt": true`。

## 3. 网络域名提示

**现象**：`npm install` 触发 "Network request outside of sandbox" 提示，需要手动允许 `registry.npmjs.org`。

**原因**：Sandbox 代理默认拦截所有外部网络请求，新域名需要用户审批。这是 sandbox 层面的提示，不受 `permissions.allow: ["*"]` 控制。

**解决**：两管齐下：
- `sandbox.network.allowedDomains` 预填常用域名（npm、GitHub、内部 GitLab 等）
- `npm install` 在 Claude 启动**之前**执行（不受 sandbox 限制），避免最常见的网络提示

## 4. macOS Seatbelt 阻断端口绑定

**现象**：`vite` 启动 dev server 报 `listen EPERM: operation not permitted 0.0.0.0:3000`。

**原因**：macOS Seatbelt 在 OS 内核层面阻断所有网络操作，只放行到 sandbox 代理端口的出站连接。`bind()` 系统调用被完全禁止，dev server 无法监听任何端口——即使绑定 `127.0.0.1` 也不行。

**解决**：将 dev server 命令加入 `sandbox.excludedCommands`，让它们在 sandbox 外执行：
```json
{
  "sandbox": {
    "excludedCommands": ["npm run *", "npx *", "vite", "next", "webpack"]
  }
}
```
其他命令（文件编辑、git 操作、npm install）仍在 sandbox 保护下。

## 5. 端口分配信息未传递给 dev 工具

**现象**：Claude 启动 dev server 时从 3000 开始逐个尝试，而不是直接用分配的端口。

**原因**：端口号写在了 CLAUDE.md 上下文里，但 Claude 没有把端口号传给 vite/npm 等子进程——这些工具不会读 CLAUDE.md。

**解决**：在启动 Claude 前设置 `PORT` 环境变量（`ENV['PORT'] = ports.first.to_s`），vite 等工具自动读取。

## 6. sandbox rm 后端口残留

**现象**：`kyb sandbox rm` 杀掉了 Claude Code 进程，但 dev server（vite）作为子进程仍在运行，端口未释放。

**原因**：`Process.kill` 只杀直接 PID，管不到 fork 出的孙子进程。

**解决**：在 `rm` 中用 `lsof -ti :PORT` 找到占用分配端口的进程，一并 kill。

## 7. Docker-in-Docker：容器内运行 kyb

在 kyb 容器内部再跑 `kyb create`（套娃）时，遇到了几个底层路径问题。

### 7.1 BuildKit 未启用

**现象**：`kyb build` 在镜像构建的 `mise install` 阶段失败，报错 `the --mount option requires BuildKit`。

**原因**：Dockerfile 用 `RUN --mount=type=cache` 加速 mise/pip 缓存，但这需要 BuildKit。宿主机 macOS 上 Docker Desktop 默认启用 BuildKit，但 Linux Docker 的 `docker build` 默认使用传统 builder，不识别 `--mount`。

**解决**：在 `Kyb::Docker.build` 和 `project_image` 中设置环境变量 `DOCKER_BUILDKIT=1`。

### 7.2 buildx 插件缺失

**现象**：设置 `DOCKER_BUILDKIT=1` 后继续报错 `BuildKit is enabled but the buildx component is missing or broken`。

**原因**：Ubuntu 24.04 的 `docker.io` 包不包含 `docker-buildx` 插件。BuildKit 需要单独的 CLI 插件才能工作。

**解决**：在容器内安装 `docker-buildx` 包。

### 7.3 Worktree 路径在宿主机不可见

**现象**：`kyb create` 创建容器成功，但新容器内项目目录为空（只有 `node_modules`）。

**原因**：kyb 的 git worktree 默认创建在 `~/.kyb/worktrees/`，这个路径在容器内的 overlay 文件系统上。当 kyb 调用 `docker run -v /home/dev/.kyb/worktrees/...` 时，宿主机 Docker daemon 找不到这个路径（它在容器内而不在宿主机上），Docker 就自动创建了空目录。

**关键认知**：Docker bind mount 的源路径是从**宿主机视角**解析的。容器内的路径对宿主机不可见。

**解决**：检测到运行在容器内时（`/.dockerenv` 存在），用 Docker named volume 替代 bind mount。容器启动后用 `docker cp` 将 worktree 内容复制到 volume 中。

### 7.4 project_path bind mount 冲突

**现象**：`docker run` 报错 `Duplicate mount point: /home/dev/projects/data-ant`。

**原因**：`run` 方法会添加两条 mount：
1. `wt_path → /home/dev/projects/<project>`（worktree）
2. `project_path → project_path`（原仓库路径）

在宿主机上，`project_path` 是 macOS 路径（如 `/Users/user/projects/data-ant`），与 worktree mount 目标 `/home/dev/projects/data-ant` 不冲突。但在容器内运行时，`project_path` 解析为 `/home/dev/projects/<project>`，与第一条 mount 的目标完全一致，导致冲突。

**解决**：当 `project_path` 与 worktree mount 目标相同时，跳过重复的 bind mount。

### 7.5 SSH 和 gitconfig 挂载也失效

**现象**：新容器内 `~/.ssh` 为空，`~/.gitconfig` 是目录而非文件。

**原因**：与 worktree 同理，`~/.ssh` 和 `~/.gitconfig` 在宿主机上是通过 virtiofs 挂载到外层容器的。宿主机 Docker daemon 无法访问 virtiofs 路径，bind mount 时创建了空目录。

**影响**：新容器内无法通过 SSH 访问 GitLab。workaround：通过 HTTPS + credentials 访问，或用 `docker cp` 复制 SSH 密钥。

### 7.6 `.git` worktree 引用断裂

**现象**：新容器内 `git submodule update --init` 报错 `fatal: not a git repository`。

**原因**：git worktree 的 `.git` 是一个文本文件，内容指向主仓库的 `.git/worktrees/<name>`。`docker cp` 复制了这个文件，但指向的路径在新容器内不存在。

**解决**：如果不需要在新容器内执行 git 操作，可以直接 `rm .git`。对于子模块等场景，在 `docker cp` 前先在源仓库初始化子模块，然后复制子模块目录到容器。或者把 `.git` 替换为完整的 `.git` 目录（通过 `git clone --no-checkout` + `git checkout-index` 等方式）。

### 7.7 基础镜像中 gradle.properties 丢失

**现象**：Gradle 构建失败 `Cannot query the value of Gradle property 'nexusUser'`。

**原因**：新容器从 kyb-base 镜像启动，但镜像中的 `~/.gradle/gradle.properties` 在容器启动时不存在。这是因为 home 目录中的缓存文件没有被持久化。

**解决**：在部署脚本中重建 `~/.gradle/gradle.properties`。


Claude Code sandbox 作为 OS 级安全边界是有效的，但在实际开发场景中有几个根本性限制：

| 问题 | 根因 | 是否可绕过 |
|------|------|:--:|
| 端口绑定被阻断 | Seatbelt 禁止 `bind()` | ✅ `excludedCommands` |
| 新域名需审批 | Sandbox 代理拦截 | ✅ `allowedDomains` 预填 |
| `--sandbox` flag 不存在 | 沙箱通过 settings.json 配置 | ✅ 写项目级 settings |
| bypass permissions 警告 | 安全提示 | ✅ `skipDangerousModePermissionPrompt` |
| 孙子进程端口泄露 | `Process.kill` 不递归 | ✅ `lsof` 清理 |

关键认知：**Claude Code sandbox 最适合"纯代码编辑"场景**（文件读写都在 worktree 内，出站网络走预批准的域名）。dev server、Docker 操作等需要网络监听或特殊权限的操作，应该通过 `excludedCommands` 排除，让它们跑在 sandbox 外。
