# `kyb create` DinD 修复与优化设计

## 问题

`kyb create` 在容器内（DinD 模式）不可用。`Kyb::Docker.run` 构造的 `docker run` 参数包含 host-only 路径的 bind mount（如 `~/.ssh`、`~/.gitconfig`、`~/.claude/settings.json`），这些路径在 macOS 宿主机上不存在（它们是当前容器内的路径）。Docker daemon 从宿主机解析失败，在子容器内创建空文件，导致 entrypoint 中 `jq` 解析失败（exit 5），`set -e` 传播退出码，entrypoint 整体崩溃，`/tmp/kyb-ready` 永不被创建，Sentinel 等待 30s 超时。

**总耗时：~33.7s（其中 30s 是超时等待）**

## 方案

在 `Kyb::Docker.run` 中检测 DinD 模式（`/.dockerenv`），跳过无效的 host-only bind mount，改用容器启动后的 tar pipe 注入。

### Step 1 — `run` 方法：DinD 模式跳过 host-only bind mount

当前 `run` 方法中所有 bind mount 无条件追加。改为在 DinD 模式下跳过以下 mount：

**保留的 mount（DinD 下有效）：**
- Env vars + label（全量保留）
- `/var/run/docker.sock`（socket 转发跨容器有效）
- `$container_name-claude:/home/dev/.claude`（named volume）
- `$container_name-worktree:/home/dev/projects/$project`（DinD named volume）
- `$container_name-node-modules:/home/dev/projects/$project/node_modules`（named volume）
- 构建缓存 `kyb-{gradle,maven,mise,pip}-cache`（named volume，已存在）
- Swift cache `kyb-swift-cache`（named volume）
- Docker args 组装（`--name`, `--hostname` 等）

**跳过的 mount（DinD 下无效，改为 tar pipe 注入）：**
- `~/.ssh` → `/home/dev/.ssh:ro`
- `~/.kyb` → `~/.kyb`
- `~/.kimi` → `/home/dev/.kimi`
- `~/.gitconfig` → `/home/dev/.gitconfig:ro`
- `~/.claude/settings.json` → `.claude-host-settings.json:ro`
- `~/.config/kyb` → `.config/kyb:ro`
- `~/.claude/skills` → `.claude-skills-host:ro`
- `~/.agents` → `/.agents:ro`
- Project path bind mount（`project_path` if different from worktree）
- Symlinks（`mounts_rw`、`mounts_ro` 中的 host 路径）
- kyb_repo（`/home/dev/kyb:ro`）

### Step 2 — `create_container` 方法：tar pipe 注入配置

容器启动 + Sentinel 等待后，增加 tar pipe 注入步骤（复用 DID `cli/did.rb` 已验证的模式）：

```ruby
if File.exist?('/.dockerenv')
  home = Dir.home
  tar_sources = []
  tar_sources << '.ssh' if File.directory?("#{home}/.ssh")
  tar_sources << '.gitconfig' if File.exist?("#{home}/.gitconfig")
  tar_sources << '.config/kyb' if File.directory?("#{home}/.config/kyb")
  tar_sources << '.kimi' if File.directory?("#{home}/.kimi")

  if tar_sources.any?
    system('bash', '-c',
      "tar -C #{home} --exclude='.ssh/agent/*' -c #{tar_sources.join(' ')} 2>/dev/null | " \
      "docker exec -i #{container.name} bash -c '" \
      "tar -C /home/dev -x " \
      "&& chown -R dev:dev #{tar_sources.map { |s| "/home/dev/#{s}" }.join(' ')} 2>/dev/null || true'")
  end
end
```

### Step 3 — 补齐 mise/pip 缓存 volume

`run` 方法中当前只挂载 `kyb-gradle-cache` 和 `kyb-maven-cache`。补充 DID 已有的 `kyb-mise-cache` 和 `kyb-pip-cache`：

```ruby
# 当前：
%w[kyb-gradle-cache kyb-maven-cache].each

# 改为：
%w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each
```

对应追加:
```ruby
args += ['-v', 'kyb-mise-cache:/home/dev/.local/share/mise/downloads']
args += ['-v', 'kyb-pip-cache:/home/dev/.cache/pip']
```

### Step 4 — DinD worktree 用 tar pipe（可选优化）

当前：
```ruby
system('docker', 'cp', "#{wt_path}/.", "#{container.name}:/home/dev/projects/#{project}/")
```

改为 tar pipe 避免 docker cp 的单文件遍历:
```ruby
system('bash', '-c',
  "tar -C #{File.dirname(wt_path)} -c #{File.basename(wt_path)} 2>/dev/null | " \
  "docker exec -i #{container.name} bash -c '" \
  "tar -C /home/dev/projects -x " \
  "&& chown -R dev:dev /home/dev/projects/#{project} 2>/dev/null || true'")
```

### Step 5 — PG 条件自启动

当前 entrypoint 全局移除了 PG 自启动（DID 不需要，普通容器也被连带移除）。在 sentinel 之后加条件启动，不阻塞启动感知：

```bash
touch /tmp/kyb-ready

# Start PostgreSQL (not needed in DID containers)
if [ -z "${KYB_DID:-}" ]; then
    pg_ctlcluster 16 main start 2>/dev/null || true
fi
```

PG cold start 实测 ~2.2s，放在 sentinel 之后不影响 CLI 返回时间。用户看到 "Container ready" 时 PG 正在后台启动，几秒后 `kyb enter` 进去 PG 已就绪。

## 预期性能

| 阶段 | 当前（DinD） | 修复后 |
|------|-------------|--------|
| Config 加载 | ~81ms | ~81ms |
| Git worktree | ~713ms | ~713ms |
| `docker run` | ~1030ms | ~800ms（mount 减少）|
| Sentinel 等待 | ~31714ms（30s 超时） | ~500ms |
| Tar pipe 注入 | N/A（崩溃） | ~200ms |
| Worktree 复制 | ~141ms（打进死容器） | ~200ms |
| PG 后台启动 | N/A（崩溃） | +~2.2s（不阻塞 CLI）|
| **CLI 总耗时** | **~33.7s** | **~2.5s** |

## 改动的文件

| 文件 | 改动 |
|------|------|
| `entrypoint.sh` | sentinel 后条件启动 PG（非 DID） |
| `lib/kyb/docker.rb` - `run` 方法 | DinD 分支跳过 host-only mount |
| `lib/kyb/docker.rb` - `create_container` | 增加 tar pipe 注入 |
| `lib/kyb/docker.rb` - `run` 方法 cache 列表 | 补齐 mise/pip 缓存 volume |
| `lib/kyb/docker.rb` - DinD worktree 复制 | 改为 tar pipe |
| `test/test_docker.rb` | 新增 DinD 注入测试 |
| `test/test_entrypoint.rb` | 新增 PG 条件启动测试 |

## 不在此范围内的

- 宿主机 macOS 上 `kyb create` 流程不变
- CLI 安装方式不改（仍走 `~/.kyb/lib`）
- daemon 架构不在此次实现
