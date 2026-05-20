# New Machine Onboarding

拷贝到新机器后，先读 `~/.claude/CLAUDE.md`。

```bash
scp -r user@host:~/kyb/docs/new-machine/ ./ && bash new-machine/scp_templates.sh
```

## 目录

| 文件 | 用途 |
|------|------|
| `scp_templates.sh` | 初始化 ~/.claude 仓库 |
| `templates/claude.md` | ~/.claude/CLAUDE.md 模板 |
| `templates/01-physical.md` ~ `05-services.md` | 五层文档模板 |

## 实验结论

SSH 探索本身没问题（主 agent 直接 SSH 到 nuc8 干得很好）。问题是 **subagent 没有上下文**——它 spawn 出来时不知道自己「在」哪里，SSH 对它只是另一个拿数据的工具，不是「我在远程工作」的信号。

22 个 agent 验证了这点（详见 `new-machine-race.md`）：

| 角色 | 成功率 | 原因 |
|------|:------:|------|
| 主 agent（有上下文） | ~100% | 知道自己在哪里，文件该写哪里 |
| subagent（零上下文） | 50-75% | 不知道 local ≠ remote |

解法方向：
1. `kyb ssh` — 让 subagent 在目标机器上跑，不再有路径歧义
2. 更好的 CLAUDE.md + `ssh new-machine` — 把上下文写死在入口文档里
| `hosts/` | 具体机器文档 (IP 命名) |
