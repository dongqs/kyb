# New Machine Template Design

Date: 2026-05-20

## 昂贵的一课 — 2026-05-20 实验结论

22 个 agent、4 轮赛跑验证了一件事：

**agent 没有「上下文切换」能力。给它 SSH，它就 SSH；给它 Write，它就写本机。**

核心发现：

| 实验 | 结论 |
|------|------|
| same prompt × 10 agents | 50% 写远程，50% 写本机 — 概率行为 |
| 反模式规则 + helper 脚本 | 拉到 75%，无法到 100% |
| 根因 | 工具接口决定行为。只要 Write 存在，agent 就会用它 |

最终答案：**不要从外面 SSH 进去，把 agent 放进去。** 这就是 `kyb ssh` 要解决的问题 — 让远程机器和本地容器一样是一等公民。

但即便放进去，也要渐进式披露上下文。这可能是今天最有价值的产出：

```
❌ 错误：给 SOP → 让 subagent 执行 → 期望一次走通
✅ 正确：小任务 → review → 纠正 → 略大任务 → review → 纠正 → 放手
```

agent 和学徒一样，先拧螺丝再看图纸。不是给本手册就让它造发动机。

所以这份文档设计的模板都在服务一个前提：**agent 和目标在同一台机器上。** 如果不是，什么模板都没用。

---

## 核心理念

### 系统论分层

机器信息按层组织，每层独立文件：

| 层 | 文件 | 内容 |
|----|------|------|
| 物理层 | 01-physical.md | 型号、CPU、内存、磁盘、LVM |
| 系统层 | 02-os.md | OS 版本、内核、系统服务 checklist |
| 网络层 | 03-network.md | 接口、IP、DNS、代理、连通性矩阵 |
| 运行时层 | 04-runtime.md | 语言运行时、包管理器、CLI 工具清单 |
| 服务层 | 05-services.md | Docker、数据库、监听端口、进程 |

### 控制论闭环

每个文件内的探索日志形成反馈循环：

```
工具检查 → 探测 → 记录结果(成功/失败+耗时) → commit → 下一轮
```

commit 越多越好。每探测一项就 commit 一次，不攒批。

### 自描述

每个文件头部回答：
- 我是谁（文件名+角色）
- 我在哪（文件路径）
- 我要干什么（记录范围）
- 我不干什么（边界）

### 选择题优先

所有字段提供常见选项，不留空填空。例如：

```
| CPU 核心数 | 2 / 4 / 8 / 16 / 32 |
| 操作系统 | Ubuntu / Debian / macOS / 其他______ |
| sshd | Y / N | Y / N | SSH 远程登录 |
```

### 安全

- 不记录 token、secret、password
- IP 和 ID 可以记录

## 文件结构

```
docs/new-machine/
├── DESIGN.md                          # 本设计文档
├── README.md                          # 引导 + 索引
├── scp_templates.sh                   # 部署脚本（只 init ~/.claude，不动任何配置）
└── templates/
    ├── claude.md                       # ~/.claude/CLAUDE.md 模板
    ├── 01-physical.md                  # ~/.claude/docs/01-physical.md 模板
    ├── 02-os.md                        # ~/.claude/docs/02-os.md 模板
    ├── 03-network.md                   # ~/.claude/docs/03-network.md 模板
    ├── 04-runtime.md                   # ~/.claude/docs/04-runtime.md 模板
    └── 05-services.md                  # ~/.claude/docs/05-services.md 模板
```

## 模板通用骨架

```markdown
# 层名

我是谁：描述。
我在哪：路径。
我要干什么：范围。
我不干什么：边界。

## 小节标题

> 📝 操作提示：每完成一步，编辑本文档记录结果并 commit。commit 越多越好。

### 子节（如 可用工具 / 当前状态）

选择题表格。

### 子节确认

我确认以上信息正确，过程已记录。
签名：________  日期：________

## 文档总复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：________  日期：________
```

### 节首提示

每个小节（`##`）开头加操作提示：

```
> 📝 操作提示：每完成一步，编辑本文档记录结果并 commit。commit 越多越好。
```

### 节尾签名

每个小节结尾加签名栏：

```
## 确认

我确认以上信息正确，过程已记录。
签名：________  日期：________
```

### 文档尾总签

每个文档末尾加最终复查：

```
## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：________  日期：________
```

## 当前状态 vs 下一版

要改的文件：

| 文件 | 当前 | 目标 |
|------|------|------|
| templates/claude.md | 纯规则 | + 自描述 + 文档索引 |
| templates/01-physical.md | 不存在 | 新建 |
| templates/02-os.md | 不存在 | 新建 |
| templates/03-network.md | 不存在 | 新建 |
| templates/04-runtime.md | 不存在 | 新建 |
| templates/05-services.md | 不存在 | 新建 |
| templates/zshrc.md | 保留（不属于分层体系，但保持兼容）|
| templates/tmux.md | 保留 | |
| templates/vimrc.md | 保留 | |
| templates/claude-init.md | 保留 | |
| README.md | 清单列表 | 更新指向新模板 |
| scp_templates.sh | 只 init ~/.claude | 保留不变 |
