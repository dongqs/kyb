# Postmortem: Round 1 — 探索 kyb-explore 容器

## 本轮踩坑

### 1. 顺序错了：先探索后搭基础设施
应该先跑 `scp_templates.sh` 再探索，结果先让 subagent 进去乱跑，触发了 entrypoint 的安装流程，违反了"不要装东西"的规则。

### 2. 入口脚本自动装东西
`kyb create` 容器的 entrypoint 会：
- start PostgreSQL
- pip install mig25 等包
- npm install / yarn install（如果有 package.json）

所以容器刚启动时不是干净的——安装已经触发。

### 3. `docker exec` 默认 root 用户
`scp_templates.sh` 在容器内跑时默认以 root 执行，但工作用户是 `dev`，导致 `~/.claude` 路径嵌套。

### 4. git safe.directory 问题
容器内文件系统是 root 创建的，git 拒绝操作。需要先 `git config --global --add safe.directory`。

### 5. git identity 未配置
新容器内没有 git user/email，`git commit` 失败。

### 6. 模板假设 SSH，实际用 docker exec
模板的「命令执行协议」写的是 `ssh user@host`，但容器内没有 sshd，实际用 `docker exec`。协议不通用。

### 7. Subagent 不知道容器内的路径结构
subagent 通过 `docker exec` 操作，但生成的文件在容器内，commit 也在容器内，导致 local/remote 分界线模糊。

### 8. `{ts}` 手填 vs 自动
subagent 不会手填时间戳，也不会按审计脚本模式操作——它直接 `docker exec bash -c 'cmd'` 了。

### 9. 时间线 cron 和 subagent 不同步
cron 每分钟检查，但 subagent 几分钟就跑完了，时间线粒度太粗。

## 需要修复的问题

| # | 问题 | 修复方向 |
|---|------|---------|
| 1 | 模板假设 SSH | 加 `docker exec` 作为另一种 remote 协议 |
| 2 | entrypoint 自动安装 | 创建容器时加 `--entrypoint sleep infinity` 跳过 |
| 3 | 默认 root 用户 | scp.sh 检测 dev 用户并 chown |
| 4 | git safe.directory | scp.sh 自动配置 |
| 5 | git identity | scp.sh 自动配置或提示 |
| 6 | subagent 不走审计脚本 | 需要更明确的 subagent prompt |
| 7 | {ts} 手填不适用于自动化 | 自动场景用 `date +%s`，手填场景保持现状 |

## 总结

Round 1：❌ 基础设施没搭就探索 → entrypoint 触发安装 → root/dev 路径混乱

Round 2：✅ 全流程一次通过

| 步骤 | 状态 | 耗时 |
|------|------|------|
| `--entrypoint sleep` 创建容器 | ✅ | 1s |
| scp_templates.sh 初始化 (dev用户) | ✅ | 3s |
| audit: 物理层 (CPU/内存/磁盘) | ✅ | 2s |
| audit: 系统层 (OS/容器检测) | ✅ | 2s |
| audit: 运行时层 (工具链) | ✅ | 2s |
| audit: 网络层 (接口/DNS/连通性) | ✅ | 10s |
| audit: 服务层 (PostgreSQL/Docker) | ✅ | 2s |
| docs/ 写入 + commit | ✅ | 3s |

**结果**: 7 个审计脚本 + 5 层文档 + 7 个 git commit，总耗时约 5 分钟。关键区别：容器启动时没触发 entrypoint，用户是 dev 不是 root，每个操作独立 commit。

Round 2 的 git log：
```
f01810c docs: complete 5-layer exploration
343f2d1 audit: services layer
799a9d6 audit: network layer
65f8e96 audit: runtime layer
44b8f76 audit: os layer
e4f6554 audit: physical layer
aebb5bd chore: init CLAUDE.md + first-touch
```

## 主 agent 踩坑记录

Round 1-2 是我亲手做的，暴露了这些问题：

| # | 坑 | 后果 |
|---|----|------|
| 1 | 先用 subagent 探索，再搭基础设施 | 触发 entrypoint 自动安装，违反规则 |
| 2 | `--entrypoint sleep` 干净启动 | ✅ 修正，跳过 entrypoint |
| 3 | `docker exec` 默认 root 用户 | ~/.claude 路径嵌套，权限混乱 |
| 4 | git safe.directory 不配 | commit 被拒 |
| 5 | 新容器没 git user.email | commit 被拒 |
| 6 | 模板假设 SSH，实际用 docker exec | 协议不匹配，subagent 卡住 |
| 7 | subagent 和我在同一个容器 | 读到 kyb 项目文档，被污染 |
| 8 | `~/.ssh` 只读挂载 | known_hosts 写不进去，每次都要 StrictHostKeyChecking |
| 9 | heredoc 嵌套 | 审计脚本模板里的 SCRIPT 块和执行脚本的 SCRIPT 冲突 |
| 10 | 以为 subagent 会自己探索 | 给了太多/太少的上下文都不行 |

Round 3 目标：subagent 在空容器运行 → SSH 到 remote → 只读 remote 的入口文档 → 按审计脚本协议探索。

## 核心教训：MVP 先行

```
❌ 实际：设计模板 → 写 5 层文档 → 建协议 → 签名闭环 → 赛跑框架 → 才第一次让 agent 跑
✅ 应该：让 agent 跑一次 → 看它怎么死的 → 修一个坑 → 再跑 → 循环
```

Round 4（一个 README + 4 行步骤 + 一个 agent）3 分钟就验证了核心假设。之后花了十几倍时间搭赛跑框架、写模板、调格式，Round 1 赛跑暴露的问题其实 Round 4 就已经能看出来。

**下次一定：先跑 MVP，再迭代。**
