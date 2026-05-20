# Boss 模式设计思路与踩坑记录

> 2026-05-19 六项目并发 onboarding 实验总结

## 背景

WISH_LIST 中的 boss 模式：

> `kyb enter --boss` — agent 不直接干活，拆任务 fork 子 agent 执行，汇总汇报。

之前的 onboarding manager 实验（buyer-center A/B 测试）和本次 6 SDK 项目并发 onboarding，本质都是 boss 模式的预演。本文档汇总这两次实验的经验，作为 boss 模式的设计输入。

## 什么是 Boss 模式

### 核心理念

当前 `kyb enter` 的工作模式是：**一个 agent 从头做到尾**。Boss 模式改为：**一个 manager agent 拆任务 → 派多个子 agent 并行执行 → 汇总汇报**。

```
传统模式（一对一）:
  agent → 从分析到执行到验证全包

Boss 模式（一对多）:
  manager → 拆任务 → fork agent A ─→ 执行
                    → fork agent B ─→ 执行
                    → fork agent C ─→ 执行
                    → 等所有人 → 汇总汇报
```

### 适用场景

| 场景 | 传统模式 | Boss 模式 |
|------|---------|-----------|
| 单项目 onboarding | ✅ 合适 | 杀鸡用牛刀 |
| 多项目并发 onboarding | ❌ 串行太慢 | ✅ 天生适合 |
| 复杂任务拆解（多模块修改） | ❌ 上下文打架 | ✅ 各模块独立 agent |
| CI 修复 + 功能开发 并行 | ❌ 切换成本高 | ✅ 分头进行 |
| 探索性任务（不确定方向） | ✅ 灵活 | 拆早了可能白做 |

## 实验回顾

### 实验 1: buyer-center A/B 测试

| 维度 | v1（无参考） | v2（有参考） |
|------|-------------|-------------|
| 耗时 | ~50min（未收敛） | ~7min（收敛） |
| 关键差异 | 从零摸索每步 | 参考项目直接避坑 |

**结论**：manager 最值钱的能力不是替 agent 干活，而是告诉它哪些坑值得踩、哪些不用。

### 实验 2: 六 SDK 项目并发 onboarding

| # | 项目 | 耗时 | 轮次 | 关键卡点 |
|---|------|------|------|---------|
| 1 | form-manager | ~29min | R4 | Lombok + Java 21 不兼容 |
| 2 | moneta | ~33min | R4 | jOOQ codegen 版本冲突 |
| 3 | rating-boost | ~17min | R4 | mise 版本回退 + DID ARM64 |
| 4 | netflix | ~5min | R4 | JaCoCo 0.8.8 + JDK 21 |
| 5 | recommendation-filter | ~7min | R4 | Java 21→8 切换 |
| 6 | recommendation-finder | ~11min | R4 | 无卡点 |

**6/6 全收敛**，但 manager 介入 3 次（修卡住的 agent）。

## 踩坑记录

### 坑 1: agent 无状态，断 session 就得重来

**现象**：agent 跑到 R3 时 session 被压缩/中断，恢复后 agent 不记得之前做了什么，DID 容器还在但 agent 停了。

**教训**：manager 需要做 checkpoint——每轮结束时写状态摘要，重连时 manager 读 checkpoint 决定从哪继续。

**设计原则**：manager 不能假设 agent 有持久记忆，关键状态必须写到文件（如 `.kyb/status.json`）。

### 坑 2: agent 不会判断"什么时候该放弃"

**现象**：v1（无参考）在 DID 容器验证时，装 JDK 失败 → 换方式装 → pip 失败 → 修 pip → 进了死胡同。v2（有参考）知道"pip3 缺失不影响流程"直接跳过。

**教训**：agent 没有全局观，需要 manager 提供"边界条件"——什么值得修，什么该跳过。

**设计原则**：manager 拆任务时附上 kyb-claude 的**决策边界**：哪些已知坑可以直接跳过、哪些环境问题可以忽略。

### 坑 3: 共享环境冲突

**现象**：两个 agent 在同一容器里跑时会打架——一个改 mise 配置、另一个被影响。buyer-center 实验时两个 agent 共享 PostgreSQL，测试数据互相污染。

**教训**：子 agent 必须有**隔离环境**。

**设计原则**：boss 模式下 fork 的每个子 agent 应该：
- 在独立的 DID 容器中执行（或至少独立工作目录）
- 使用独立的数据库（或独立 schema）
- 不共享 mutable 状态

### 坑 4: 无限轮询

**现象**：检查 agent 进度的循环跑了 50+ 轮，每次手动执行相同命令，浪费大量上下文。

**教训**：轮询是人类的活，不是 AI 的活。需要自动通知机制。

**设计原则**：boss 模式应该：
- 子 agent 完成时主动通知（`kyb notify done` 或写 sentinel 文件）
- manager 监听通知而不是轮询
- 超时机制：超过预期时间未完成 → manager 介入

### 坑 5: 参考项目价值巨大

**现象**：有参考项目的 agent 比无参考的快 7x，不是能力差异，是信息不对称。

**教训**：manager 的核心工作之一是准备上下文。

**设计原则**：拆任务时 manager 应附上：
- 相似任务的踩坑记录
- 已知环境限制
- 项目间差异提示

### 坑 7: subagent 不自验就报 done

**现象**：subagent 改完代码直接报完成，没有跑任何验证（语法检查、编译、测试）。manager 以为搞定了，实际可能代码都没 commit、语法有错、功能不对。

**本次实例**：派两个 agent 修 kyb 基础设施问题。Agent A 改了 `mise.config.toml` + `Dockerfile` 后既没 commit 也没验证语法；Agent B 改了 `entrypoint.sh` 但没做 shellcheck 或运行测试。manager 不得不亲自下场验货——这不该是 boss 干的活。

**根因**：manager 派活时 prompt 只写了"改什么"，没写"改完要验证"。subagent 按字面执行——做到"改完"就停了。

**教训**：**subagent 的完成条件不应该是"改完了"，而是"验证通过了"。**

**设计原则**：
- 每个 subagent 的 prompt **末尾必须有验证步骤**——具体命令和期望结果
- subagent 必须**跑完验证、贴出证据**才算 done
- 验证失败的 subagent 报告失败原因，manager 判断是重试、介入还是换方案
- manager 只看验证报告，不下场重新验证——那是信不过 subagent 的表现

**prompt 模版**：
```
任务: <做什么>

改完后执行以下验证，全部通过才能报 done：
1. `bash -n <file>` → 输出为空（语法正确）
2. `grep <pattern> <file>` → 匹配成功（改动在正确位置）
3. <运行相关测试> → 全部通过

完成后 commit 并 push。汇报时附上每条验证命令的输出。
```

### 坑 6: 测试非幂等（原坑 6，保持编号不变）

**现象**：moneta 和 buyer-center 的测试改了数据库状态，第二次跑就失败。agent 不知道"truncate 重跑"这个模式。

**教训**：数据库测试的幂等性是常见问题，应在参考文档中覆盖。

**设计原则**：manager 应维护一份"常见踩坑模版"，按项目类型（Java/Python/有 DB/无 DB）分类，拆任务时自动匹配附上。

## Boss 模式需求

### P0 — MVP

```
kyb enter --boss <description>
```

1. **Manager 分析需求** → 判断是否需要拆任务
2. **拆任务** → 如果单 agent 可搞定，直接退化为普通 enter
3. **Fork 子 agent** → 每子任务一个独立容器/会话
4. **监控** → 等所有子 agent 完成或超时
5. **汇总** → 整合结果，汇报

### P0 — Checkpoint 机制

```
.kyb/boss-status.json
{
  "task": "onboard 6 sdk projects",
  "state": "running",
  "checkpoints": [
    {"round": 1, "status": "done", "time": "T+10min"},
    {"round": 2, "status": "running", "time": "T+15min"}
  ],
  "subtasks": [
    {"name": "form-manager", "agent": "a0b9...", "status": "done"},
    {"name": "moneta", "agent": "afd3...", "status": "blocked"}
  ]
}
```

重连时 manager 读此文件恢复上下文。

### P1 — 决策边界

任务描述附带的元数据：

```yaml
task:
  description: "onboard form-manager"
  known_pitfalls:
    - "Lombok 1.18.22 与 Java 21 不兼容，需要 Java 17"
    - "mise trust 可能在 DID 容器中缺失"
  skip_conditions:
    - "pip3 缺失 → 跳过（uv 全覆盖）"
    - "Apollo/RocketMQ 不在本地 → 测试有 mock"
  timeout: "30min"
```

### P1 — 通知机制

- 子 agent 完成 → `kyb notify done` + 写结果文件
- manager 监听 sentinel 文件（非轮询）
- 超时 → manager 主动检查 + 介入

### P2 — 隔离策略

- 默认：每个子 agent 在独立的 DID 容器中执行
- 轻量：同一容器但独立工作目录 + 独立 DB schema
- 共享：低风险任务共享环境（节省资源）

### P2 — 参考项目匹配

根据项目技术栈自动匹配最相似的已 onboarding 项目，附其 `.kyb.md` 和踩坑记录。

## 何时开 Subagent：决策框架

拆不拆任务、开不开 subagent，是 boss 模式最核心的决策。以下是实验验证的四维判断框架：

### 四维决策树

```
任务来了
├─ 路径清晰？── 不清晰 → manager 先探索，探清了再拆
└─ 路径清晰？
    ├─ 能并行？── 不能 → manager 自己干
    └─ 能并行？
       ├─ 任务够大？── 太小（<5min） → manager 自己干
       └─ 任务够大？
          ├─ 会打架？── 会 → 串行或重新设计拆分方式
          └─ 不打架 → ✅ 拆成 subagent
```

### 维度 1：路径清晰度

是否知道"具体要做什么、每一步怎么做"？

| 路径 | 典型场景 | 决策 |
|------|---------|------|
| 清晰 | 按 .kyb.md onboarding、修已知 bug、执行标准流程 | ✅ 可拆 |
| 模糊 | 性能排查、架构分析、根因调查 | ❌ manager 先探索 |
| 半清晰 | 需求明确但实现路径不确定 | 拆探索任务 + 执行任务 |

路径模糊的任务拆了也是白拆——subagent 会频繁卡住等 manager 决策，沟通成本反而更高。

### 维度 2：并行度

子任务能否互不依赖同时进行？

| 并行度 | 典型场景 | 决策 |
|--------|---------|------|
| 高 | 多个独立项目的 onboarding | ✅ 全并行 |
| 中 | 一个项目的多个独立模块 | 并行但注意隔离 |
| 低 | 前后依赖的任务链 | 串行 pipeline |

伪并行比串行更糟——subagent 等另一个 subagent 的输出时，两边都在空转。

### 维度 3：任务粒度

多大才算"够大"？

| 粒度 | 耗时 | 决策 | 原因 |
|------|------|------|------|
| 过大 | >2h | ❌ 需再拆 | subagent 上下文撑不住，且失败成本高 |
| 适中 | 10-30min | ✅ 理想粒度 | 够独立执行，失败重来成本低 |
| 偏小 | 2-5min | ⚠️ 边缘 | 开 subagent 的上下文开销 ≈ 自己做 |
| 过小 | <1min | ❌ manager 自己干 | 上下文开销倒挂 |

开一个 subagent 的上下文成本约 5-10K token（描述任务 + 附参考 + 取结果）。如果任务本身只要 30 秒，不值。

### 维度 4：任务间耦合

子任务之间会不会互相影响？

| 耦合度 | 典型场景 | 风险 | 隔离策略 |
|--------|---------|------|---------|
| 无 | 不同项目的 onboarding | 无 | 随便并行 |
| 弱 | 同项目不同模块的修改 | merge 冲突 | 独立工作目录 |
| 中 | 共享数据库的测试 | 数据污染 | 独立 DB / 独立 schema |
| 强 | 改同一个文件 | 必然冲突 | 不能并行，串行做 |

**铁律**：耦合度中以上的任务，要么不并行，要么花成本做隔离。不隔离的并行 = 等着修冲突。

### 综合判断示例

| 任务 | 路径清晰 | 能并行 | 够大 | 不打架 | 结论 |
|------|---------|-------|------|-------|------|
| 6 个项目 onboarding | ✅ | ✅ | ✅ | ✅ | **拆！** |
| 修一个 CI yaml | ✅ | ❌ | — | — | 自己干 |
| "看下日志为什么报错" | ❌ | — | — | — | 先探索 |
| 改两个微服务的 API | ✅ | ✅ | ✅ | ⚠️ | 拆但定好 interface |
| 加一个 log | — | — | ❌ | — | 顺手做了 |
| 升级全项目依赖 | ✅ | ✅ | ✅ | ⚠️ | 拆但每模块独立 MR |

### 设计原则

四维框架最终转化为一条可执行的 heuristics：

> **开 subagent 的条件：路径清晰 + 能并行 + >5min + 不打架。四项缺一不可。**

manager 评估任务时逐项检查，有一项不满足就不拆。

## 未解决的问题

1. **上下文成本**：每个子 agent 消耗独立的上下文窗口。6 个 agent 并行相当于 6x 成本。如何平衡并行度和成本？
2. **Manager 本身的上下文**：manager 持有所有子 agent 的摘要。当子任务很多时，manager 的上下文也会被撑爆。需要摘要压缩策略。
3. **agent 失败处理**：子 agent 卡住了，manager 是重试、换人、还是自己上？判断标准是什么？
4. **安全性**：子 agent 能做什么不能做什么？权限怎么控制？避免一个 agent 乱来影响整个系统。
5. **和现有 kyb 命令的关系**：boss 模式是 `kyb enter --boss` 还是 `kyb boss`？DID 容器已经是某种程度的隔离，是否需要更深层的 sandbox？

## 下次迭代

1. 整理 boss 模式的 PRD，明确 MVP 边界
2. 设计 checkpoint 文件格式
3. 实现最简原型：manager 在容器内 fork Claude Code 子进程执行任务
4. 用已有的 onboarding 场景验证

## 参考链接

- WISH_LIST.md — [boss 模式 Issue #20](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/20)
- [Onboarding Manager 方法论与 A/B 测试](onboarding-manager.md) — 三层 onboarding 模型、双 agent 实验
- [SDK Batch 赛事直播](race-live.md) — 6 项目并发 onboarding 时间线与结果
- [kyb Issue #11: DID 容器工具链问题](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/11) — root vs dev 用户不一致
- [kyb Issue #14: 容器内缺少 gh CLI](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/14)
- [kyb Issue #9: DID 容器 /etc/hosts 配置](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/9)
- [kyb Issue #10: 隔离沙箱](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/10)
