# kyb: Worktree 迁移到 Direct Mount + Clone 模式

## 背景

kyb 容器当前使用 git worktree 挂载项目代码。worktree 的设计初衷是让宿主和容器在同一 repo 上并行开发互不干扰，但实际上带来了更多问题：

1. **agent 被 worktree 的 git 限制卡住** — `git pull` / `git rebase` / `git checkout` 经常失败，agent 不认识 worktree 的特性
2. **超出 scope** — 大部分场景宿主并不需要和容器并行开发同一个 repo，worktree 的复杂度得不偿失
3. **`kyb rm` 残留** — 需要清理 worktree 文件、本地分支，逻辑复杂

核心判断：**并行开发和 mount 天然冲突，不应同时照顾。** 默认走 mount，要并行走 clone，硬要并行就去原地开多个手动 repo。

## 方案

去 worktree，改为两种 mount 模式：

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| **默认（direct mount）** | 宿主 repo 直接 rw bind-mount 进容器 | 宿主不（需）在容器生命周期内 git 操作 |
| **`--clone`** | `git clone` 独立副本，容器专享 | 需要容器内外并行开发、不希望宿主被干扰 |

## 两种模式对比

| | 默认（direct mount） | `--clone` |
|---|---|---|
| 容器内 git | ✅ 完整 repo，无限制 | ✅ 完整 repo，无限制 |
| 宿主并行 git | ❌ 会冲突，注意避开 | ✅ 完全隔离 |
| 容器内改代码 | ✅ 宿主直接可见 | ⚠️ 宿主要看需 `kyb exec` |
| 磁盘 | 0 额外占用 | 独立 clone（~= 一个 repo） |
| 创建速度 | 秒级 | 几秒（本地 clone） |

## 架构

### 默认模式

```
kyb create project branch
  ├─ 宿主机 project 所在目录
  │   ├── git fetch origin
  │   ├── git checkout master
  │   └── git merge --ff-only origin/master   ← 保证 master 最新
  │
  └─ rw bind-mount ──→ 容器 ~/projects/project/
                            └── agent 在完整 repo 上自由 git 操作

同时：
  宿主 ~/ 整个目录 ──ro──→ 容器 ~/projects-host/
  所有项目随意参考，新增项目自动可见
```

### --clone 模式

```
kyb create --clone project branch
  ├─ git clone ~/path/to/project ~/.local/share/kyb/clones/project/kyb-project-branch/
  │  (本地 clone，对象文件硬链接，秒级完成)
  │
  └─ rw bind-mount ──→ 容器 ~/projects/project/
                            └── agent 的独立完整 repo

宿主原有项目目录完全不受影响。
```

### kyb rm

两种模式统一，`kyb rm` 只做：

```
docker stop && docker rm
docker volume rm <claude-volume>
docker volume rm <worktree-volume> (DID 场景)
```

--clone 模式额外：
```
git branch -D (本地分支，若未删除)
rm -rf <clone-dir>
```

宿主 repo 永远不动。

## Git Flow

### 创建前（宿主侧）

```
git fetch origin
git checkout master
git merge --ff-only origin/master
```

容器启动后宿主避免在同一 repo 上 git 操作（默认模式注意，--clone 模式随便）。

### 运行中（agent 侧）

- 初始在 master
- `git checkout -b feature/xxx`
- `git add && git commit && git push`
- MR → merge
- `git checkout master && git pull`（完整 repo，无限制）
- 循环

### 删除时

`kyb rm` 后提示：

```
==> 远端分支 kyb/xxx 未删除，如需清理请手动 git push origin --delete kyb/xxx
```

## 多容器冲突检测

**问题**：默认模式（direct mount）下，同一项目开多个容器 → 多个 agent 同时操作宿主 repo → git 混乱。

**方案**：

`kyb create` 时检测：同一项目的默认模式容器是否已存在？
- 否 → 正常创建
- 是 → 新建容器启动时，注入 prompt：

> ⚠ 注意：当前项目已有其他容器也在使用。你们在共享同一个 git repo，git 操作（切分支、rebase）可能互相影响。
> 如果希望完全隔离，建议改用 `--clone` 模式创建容器，只需改 config.yml 加 `clone: true` 一行。

已有容器的 agent 下次 `kyb enter` 或者启动时同样收到注入提示。

--clone 模式开多个容器无此问题，各自独立 repo。

## 宿主机 ~/ → 容器 ro mount

启动时 mount 宿主 `~` 到容器 `~/projects-host/`（只读）：

```
-v ~/:/home/dev/projects-host:ro
```

无论宿主的项目在 `~/leyan/`、`~/github/` 还是哪里，agent 都可以 `cd ~/projects-host/` 参考任何已有代码。

## 改动范围

### 移除

| 文件 | 改动 |
|------|------|
| `lib/kyb/git.rb` | 删除 `setup_worktree` / `remove_worktree` / `delete_local_branch` |
| `lib/kyb/cli/manage.rb` | `rm` / `prune` 中删除所有 git 清理逻辑 |
| `lib/kyb/docker.rb` | `create_container` 中删除 worktree 创建调用和 `cp_files` |
| `lib/kyb/exit_flow.rb` | 重写检查逻辑（不检查 worktree，只检查 diff + cherry） |

### 新增

| 文件 | 改动 |
|------|------|
| `lib/kyb/docker.rb` | `create_container` 启动前 `ensure_master_synced(project)` |
| | `create_container` 接收 `clone:` 参数，--clone 时走 clone 逻辑 |
| | 创建时检测同项目多容器冲突注入 prompt |
| `lib/kyb/container.rb` | 移除 `worktree_path` / `git_branch` 方法 |
| | 保留 `Container` 对象作为标识符 |
| `lib/kyb/exit_flow.rb` | 检查宿主 repo diff + cherry，不再检查 worktree |
| `lib/kyb/cli/create.rb` | 解析 `--clone` flag |
| `entrypoint.sh` | 注入多容器冲突 prompt（从 docker label 或 env 读取） |

### 不变

- `config.yml` 格式
- `kyb create` / `kyb rm` CLI 基本接口
- `kyb sandbox`、`kyb did`、tts、notify

## ExitFlow

```
☐ 工作区干净？  git diff --quiet
☐ 已推送？     git cherry 为空
全部通过 → 问是否删容器
不通过 → 警告，不删，手动 kyb rm
```

不检查 worktree 引用、不删分支。ExitFlow 只检查当前项目宿主 repo 的脏状态。

## DID 场景

- 默认模式：宿主机路径 Docker daemon 可见，DID 子容器可直接 bind-mount
- --clone 模式：clone 目录在宿主机路径上，同样可直接 bind-mount
- 不走 `docker cp`，DID 子容器内也是完整 repo

## K8s 展望

`--clone` 模式的 clone 逻辑可直接复用为 K8s 模式的代码源：

```
源         存储         mount
GitLab ──→ PVC ──────→ Pod 容器
```

改为 `git clone GitLab_URL→PVC` 即可，架构不变。

## 不涉及

- kyb sandbox
- kyb did CLI
- 构建系统 / Dockerfile
