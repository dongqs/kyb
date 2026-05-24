# Evolution Timeline

我是怎么长成这样的。按天记录结构性的变化。

---

## Day 1: 从 0 到 12+ 并行

**结构变化：**
- Worktree 死亡，Mount 上位 → 体积管理模型彻底改变
- Sandbox 模式删除 → 简化到 create/enter/exec/rm
- DID 从死亡螺旋到 15/17 pass → Docker-in-Docker 容器架构可用

**能力变化：**
- 12+ 并发 agent 实战验证
- 17 项目一夜 onboard → onboarding pipeline 成形
- Cross-review 成为铁律 → QA 管道上线

**基础组件新增：**
- `check.rb` (预检系统)
- `exit_flow.rb` (退出清理)
- Docker-in-Docker 模型
- OODA cron（现已进化为 patrol 系统）

## Day 2: 从工具到 Runtime

**认知变化（最重要）：**
我从 CLI 工具被重新认识为 Agent Runtime。这改变了一切。

**结构变化：**
- `kyb-infra-ck` + `agent_events` 表 → 数据管道上线
- `kyb morning` 命令 → 运维工具
- 自动 metrics 采集 → 可观测性基础

**修复：**
- 6 处 Shellwords.escape 注入修复
- CI `in_container?` 误判修复（5 世界观围攻）
- rm cname bug

**新增组件：**
- `Kyb::Config` 项目配置系统
- `Kyb::Reporter` CK 事件上报
- 自动 metrics 采集循环

## Night 1: 无人值守验证

**结构变化：**
- Grafana 从 4 个空面板 → 48 个正常面板
- ACR 镜像缓存上线
- PG 全家桶 (14/15/16/17)
- 40+ 轮零异常巡检 → 系统可信度建立

**新增组件：**
- Patrol 巡检 cron
- Registry cache 代理
- Grafana dashboard provisioning

## Day 3: 健壮性

**结构变化：**
- Boss 重生 → 容器生命周期管理规范化
- 95 项安全+健壮性审计 → 修复优先级出炉
- 9 MR 合入（安全/功能/文档/死代码）

**关键决策：**
- Go 重写 ❌ → Tebako 二进制打包 ✅
- 决定全面 audit 而非零散修

**安全修复：**
- Heredoc 注入
- Shell 注入 (Open3.capture3)
- Branch 名校验
- doctor 命令接线

## Night 2: 可观测性设计

**结构变化：**
- 7 阶段大规模并行设计 -> 可观测性架构定案
- Vector 直写 CK（不加 Kafka）-> 数据管道架构决策
- cc-connect 原生 hooks -> 飞书集成方案
- Grafana Provisioning as Code -> 监控 IaC

**新增知识：**
- 138 份打标文档（NOW/LATER/NEVER/MAYBE）
- 5 支预备队 ready-to-go
- 正交分解方法论用于 agent 大规模派工

## Day 4: 稳定化

**结构变化：**
- 4 个波动源根因消灭（nuc8 隧道/sing-box 端口/网络/配置）
- `entrypoint.sh` infra-boss 启动块新增 autossh 自动保活
- 稳定交接清单写入文档

**新增组件：**
- autossh 隧道自愈
- sing-box 配置从 volume 改宿主机只读 mount
- `NEW-BOSS-QUICK-REF.md`

## 形态变化总结

```
Day 1              Day 2              Day 3              Day 4
单容器             +CK 管道            +审计框架           +自愈
+并行派工           +Grafana            +安全修复            +稳定文档
+Mount 模型         +Agent Runtime 认知  +Boss 重生          +波动源消灭
+17 项目            +记忆分层            +Tebako 决策
+DID 可用           +morning 命令        +可观测性设计
```
