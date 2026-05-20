# {new-machine-remote-hostname}

我是谁：记录 remote:ssh {new-machine-ssh-user}@{new-machine-ssh-host} 的根文档。
我在哪：remote:~/.claude/CLAUDE.md
我要干什么：给 AI agent 定义规则，引导逐层探索这台机器。
我不干什么：不装软件、不改配置、不生成 key。

**agent 注意：你在 local 容器内。所有探测命令通过审计脚本模式发到 remote 执行。**

## 命令执行协议

audits/ 里已预填了 `kyb-20260101-000000-first-touch.sh` 作为命名范例。
时间戳格式：`YYYYMMDD-HHMMSS`，每次探测写新脚本时把 `{ts}` 换成实际时间，确保全局唯一。

| 步骤 | 位置 | 操作 |
|------|------|------|
| 1 | local | 写脚本到 `/tmp/kyb-{ts}-{desc}.sh` |
| 2 | local→remote | `scp` 到 `remote:~/.claude/audits/` |
| 3 | remote | `ssh remote bash ~/.claude/audits/kyb-{ts}-{desc}.sh` |
| 4 | remote | `ssh remote "cd ~/.claude && git add audits/ && git commit"` |

```bash
# === local === 写脚本，{ts} 每次手填不重复
cat > /tmp/kyb-20260101-120000-phy-cpu.sh << 'SCRIPT'
lscpu | grep 'model name'
free -h
SCRIPT

# === local→remote ===
scp /tmp/kyb-20260101-120000-phy-cpu.sh {new-machine-ssh-user}@{new-machine-ssh-host}:~/.claude/audits/

# === remote ===
ssh {new-machine-ssh-user}@{new-machine-ssh-host} bash ~/.claude/audits/kyb-20260101-120000-phy-cpu.sh

# === remote ===
ssh {new-machine-ssh-user}@{new-machine-ssh-host} "cd ~/.claude && git add audits/ && git commit -m 'audit: phy cpu info'"
```

## 规则

> 📝 操作提示：逐条确认后 commit。

- 只记录和探索，不要装任何东西（包括不要 apt install、brew install、pip install 等）
- 不要改 remote 的现有配置（~/.zshrc、~/.tmux.conf、~/.vimrc 等）
- 不要生成 SSH key
- 不要修改 templates/ 里的文件
- 文档写到 `remote:~/.claude/docs/`，审计脚本写到 `remote:~/.claude/audits/`
- 每完成一个表格或一项探测就 commit，不要攒批
- 把 `{new-machine-remote-hostname}`、`{new-machine-ssh-user}`、`{new-machine-ssh-host}` 替换为实际值，不要留字面量
- 不要留空白字段，填不出来记"未知"
- 不记录 token、secret、password
- IP 和 ID 可以记录

### 确认

我确认以上规则。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 文档索引

> 📝 操作提示：确认各层文档存在后标记。

| 层 | remote 路径 | 内容 | 已完成 |
|----|------------|------|--------|
| 物理 | remote:~/.claude/docs/01-physical.md | 硬件、CPU、内存、磁盘 | Y / N |
| 系统 | remote:~/.claude/docs/02-os.md | OS、内核、系统服务 | Y / N |
| 网络 | remote:~/.claude/docs/03-network.md | IP、端口、DNS、代理 | Y / N |
| 运行时 | remote:~/.claude/docs/04-runtime.md | 语言、工具、版本 | Y / N |
| 服务 | remote:~/.claude/docs/05-services.md | Docker、DB、进程 | Y / N |

### 确认

我确认已创建各层文档。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)
