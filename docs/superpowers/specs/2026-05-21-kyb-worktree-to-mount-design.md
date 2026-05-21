# kyb: Worktree to Direct Mount Migration Design

## 背景

kyb 容器当前使用 git worktree 挂载项目代码：`kyb create` 时在宿主 repo 上创建 worktree 分支，再 bind-mount 进容器。这个模式有几个问题：

1. **agent 被 worktree 卡住** — 容器内 Claude Code agent 在 worktree 上执行 `git pull` / `git rebase` 等操作时失败，因为 worktree 的 git 限制不同于常规分支
2. **内外迭代不清晰** — worktree 将容器内外 git 状态耦合，导致 agent 不知哪些操作该做、哪些会失败
3. **`kyb rm` 复杂** — 需要清理 worktree 文件、本地分支，git 状态残留

## 方案

取消 worktree，改为将宿主机项目目录直接 rw mount 进容器。容器内拿到完整、独立的 git repo，所有 git 操作正常可用。

## 架构

```
kyb create 前（宿主侧自动）：
  宿主 ~/projects/<project>/
    ├── 完整 git repo，在 master 分支且最新
    │   git fetch origin && git checkout master && git merge --ff-only origin/master
    └── rw mount ──→ 容器 ~/projects/<project>/
                        └── 完整 git repo → agent 任意 git 操作

所有已注册项目：
  宿主所有 config.yml 中注册的项目目录 → rw mount → 容器 ~/projects/ 下对应目录
  agent 主用当前项目，随时可看其他项目代码
```

## Git Flow

### 创建前（宿主侧）

`kyb create` 自动执行：

```
git fetch origin
git checkout master
git merge --ff-only origin/master
```

确保宿主 repo 在 master 且与 origin/master 同步。容器启动后，宿主不应在容器生命周期内操作同一 repo。

### 运行中（agent 侧）

- 初始在 master
- `git checkout -b feature/xxx` 切功能分支
- `git add && git commit && git push` 正常提交
- 创建 MR → 合入 master
- `git checkout master && git pull` 拉新代码（完整 repo，无限制）
- 循环

### 删除时（宿主侧）

`kyb rm` 只做：

```
docker stop && docker rm
docker volume rm <claude-volume>   # agent settings/claude 数据
docker volume rm <worktree-volume> # DID 场景的 named volume
```

**不动 git repo**，不删分支。分支已 push 则远端保留，未 push 则本地保留提示。

## 改动范围

### 移除

| 文件 | 改动 |
|------|------|
| `lib/kyb/git.rb` | 删除 `setup_worktree` / `remove_worktree` / `delete_local_branch` |
| `lib/kyb/cli/manage.rb` | `rm` / `prune` 中删除所有 git 清理逻辑 |
| `lib/kyb/docker.rb` | `create_container` 中删除 worktree 创建调用和 `cp_files`（不再需要，宿主 repo 直接可用） |
| `lib/kyb/cli/create.rb` | 删除 stale image 提示（不阻塞） |
| `lib/kyb/exit_flow.rb` | 重写检查逻辑 |

### 新增

| 文件 | 改动 |
|------|------|
| `lib/kyb/docker.rb` | `create_container` 启动前加 `ensure_master_synced(project)` 逻辑 |
| `lib/kyb/container.rb` | 移除 `worktree_path` / `git_branch` 方法，不再需要 |
| `lib/kyb/exit_flow.rb` | 改为检查宿主 repo 的干净状态（diff 和 unpushed commits） |

### 不变

- `entrypoint.sh` — 容器启动流程不受影响
- `config.yml` 格式 — 项目配置不变
- `kyb create` / `kyb rm` CLI 接口 — 用户命令不变

## ExitFlow

agent 退出后检查宿主 repo（rw mount 进来，宿主可直接检查）：

```
☐ 工作区干净？  git diff --quiet
☐ 已推送？     git cherry 为空
全部通过 → 问是否删容器
不通过 → 警告，不删，手动 kyb rm
```

与当前区别：不检查 worktree 引用、不删分支。ExitFlow 只检查当前项目宿主 repo 的脏状态。

## DID 场景（容器内套容器）

Worktree 模式下 DinD 用了 `named volume + docker cp` 的变通方案。改成 mount 后：

- 主容器已有完整 repo via bind-mount → Docker daemon 可见此路径
- DID 子容器可直接 bind-mount 同一宿主机路径（不走 `docker cp`）
- DID 子容器内也是完整 repo，git 操作正常

## 不涉及

- `kyb sandbox` 模式（宿主机直跑 sandbox）不受影响
- `kyb did` CLI 接口不变
- 构建系统 / Dockerfile 不变
