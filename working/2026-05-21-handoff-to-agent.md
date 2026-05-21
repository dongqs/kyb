# Handoff to Container Agent — 2026-05-21

## 已完成

worktree 已从 kyb 移除，改为 direct mount + clone 模式。具体改动：

- **默认 mount**：`kyb create` 直接 mount 宿主 repo，不再用 git worktree。agent 在容器里拿到完整 git repo，所有操作正常
- **`--clone` 模式**：`kyb create --clone` 创建独立 git clone，适合并行
- **`kyb rm` 简化**：只删容器+volume，不碰 git
- **sandbox 模式已删除**（不再需要）
- **CI 修复**：加 bundle install，更新测试列表
- **Claude Code 修复**：entrypoint 启动时自动补跑 native binary

## 需要验证

容器里主要确认以下几点：

### 1. git 操作正常（worktree 时代被卡的场景）

```bash
cd ~/projects/<项目>
git pull                    # 应该正常工作
git checkout -b test/xxx    # 应该正常
git rebase master           # 应该正常
```

### 2. kyb 新功能

```bash
kyb create <项目>-<分支>            # 默认 mount 模式
kyb create --clone <项目>-<分支>    # 隔离 clone 模式
kyb rm <项目>-<分支>                # 干净删除，不碰宿主 git
```

### 3. Claude Code 启动

```bash
# 如果提示 "native binary not installed"
# 手动跑一次：
LATEST=$(ls -d /home/dev/.local/share/mise/installs/npm-anthropic-ai-claude-code/*/lib/node_modules/@anthropic-ai/claude-code/ 2>/dev/null | sort -V | tail -1)
node "$LATEST"install.cjs
```

### 4. kyb 自身开发

改 kyb 代码时必须用 `--clone` 模式，避免干扰宿主的 `~/.kyb/`（也是 build context）：

```bash
kyb create --clone kyb <分支>
# 容器内验证：
alias kyb-test='ruby -Ilib bin/kyb.rb'
kyb-test version
```

## 已知问题

- `kyb build` 刚跑完，镜像已包含最新的 entrypoint.sh
- `kyb preflight` 预检都通过了
- 买了域名 `kybbky.com`，还没想好用途

／人◕ ‿‿ ◕人＼
