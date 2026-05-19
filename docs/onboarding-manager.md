# Onboarding Manager — 三层 onboarding 实验记录

## 背景

传统 onboarding 是一对一的：一个 agent 从头做到尾，既管基础设施又跑流程还做验证。
问题在于不可 scale——同时 onboard N 个项目需要 N 个 agent 各干一遍完全相同的活。

## 三层模型

```
Onboard Manager（你）
├── 分析项目结构，写 .kyb.md 初稿
├── 派 Onboarding Agent 去沙箱跑流程
│   ├── Round 1: 跑通，每卡一次 commit push
│   ├── Round 2: 优化，记录冷热耗时
│   └── Round 3-4: 派 Verification Agent 验收
└── 只看最终报告，卡了再介入修 kyb 层
```

## 本次实验 (2026-05-19)

### 项目: buyer-center (base-service/buyer-center)

**技术栈**: Java 21 + Maven multi-module, PostgreSQL, mig25

**MR**: https://git.leyantech.com/base-service/buyer-center/-/merge_requests/76

### A/B 测试设计

为了验证"参考项目踩坑记录"是否真的能加速 onboarding，设计了双 agent 对比：

| Agent | 策略 | 参考项目 |
|-------|------|---------|
| **v1** (a911c07a) | 无参考，从零探索 | 无 |
| **v2** (a8ce7c02) | 附 dredge-lxk 踩坑记录 | dredge-lxk 的 6 条已知坑（mise 权限、JAVA_HOME、.m2 所有权、测试非幂等、mise 激活、maven 路径） |

### 流程

1. **Manager 分析** → 克隆项目、读 CI/README/pom.xml、判断技术栈
2. **Manager 写初稿** → 基于模版生成 `.kyb.md`，注意 buyer-center 比 dredge-lxk 简单得多（JDK 21 预装、无 CK/Redis）
3. **Manager 附参考项目** → 把相似项目的 `.kyb.md` 踩坑记录给 agent，避免重复踩坑
4. **Manager 派两个 agent** → 同时启动 v1（无参考）和 v2（有参考），各自独立执行 4 轮
5. **Manager 监控** → cron 每 2 分钟检查一次进度

### 观察

#### v2（有参考）— ✅ 收敛

| 轮次 | 耗时 | 说明 |
|------|------|------|
| Round 1 | ~2min | mise 权限、JAVA_HOME、mig25 cwd 等文档更新后 commit push |
| Round 2 | ~1min | 热启动编译 32s，增量编译 15s，优化表已更新 |
| Round 3 | ~1min | DID 容器创建 + Docker-in-Docker 验证（拉取并运行 alpine 镜像） |
| Round 4 | ~3min | 最终验证。遇到 buyer-center-common 非幂等测试失败 → truncate 重跑 → 通过 |
| **合计** | **~7min** | 2 commits pushed，所有测试通过 |

v2 的 7 分钟里有 ~3 分钟是等 `mvn test`。真正踩坑时间很少，因为：
- 参考记录直接告诉它要 `chown ~/.m2` 和 `~/.local/share/mise/downloads`
- 知道 `eval "$(mise activate bash)"` + `export JAVA_HOME` 是必做步骤
- 遇 buyer-center-common 测试失败时，参考记录提示"非幂等，truncate 重跑"

#### v1（无参考）— ❌ 未收敛（已终止）

| 轮次 | 耗时 | 说明 |
|------|------|------|
| Round 1 | ~15min | 从零摸索 mise 激活、JAVA_HOME、maven 路径；修改了 data-service 的 test.sql 试图修复测试数据问题 |
| Round 2 | ~5min | 测热启动耗时 46s，更新了 .kyb.md 耗时表 |
| Round 3 | ~30min+（未完成） | 创建 DID 容器后陷入死胡同——装 JDK、修 mise 权限、装 pip 包、修 settings.xml、编译失败 |
| **合计** | **~50min+（未收敛）** | 3 commits pushed，但测试从未全部通过 |

v1 失败的原因：
- 没有参考项目，每一步都在重复 dredge-lxk 已经踩过的坑（mise 权限、JAVA_HOME、.m2 所有权）
- Round 1 花大量时间 debug 测试数据问题（seller 数据不一致），而 v2 直接 truncate 重跑
- Round 3 DID 容器验证成了无底洞——DID 容器不共享宿主机 mise installs 和 settings.xml，需要从零搭建
- 不知道什么时候该放弃一个方向换另一种方法

### 结论

| 维度 | v1（无参考） | v2（有参考） |
|------|-------------|-------------|
| **总耗时** | ~50min（未收敛） | ~7min（收敛） |
| **Rounds 完成** | 2.5 / 4 | 4 / 4 |
| **commits** | 3 | 2 |
| **测试通过** | 未完全通过 | ✅ 全部通过 |
| **关键优势** | — | 参考项目直接避开了 mise/JAVA_HOME/.m2 等已知坑 |
| **最大教训** | 没有参考信息时 agent 会深挖到源码级，无法判断优先级 | 有了参考边界，知道什么时候该 truncate 而不是 debug |

**核心发现：给 agent 附上相似项目的踩坑记录，约能节省 85%+ 的 onboarding 时间。**

差异的根本原因不是 agent 能力强弱，而是 **信息不对称**。v1 不知道哪些是"已知坑可以跳过"，哪些是"真正需要解决的项目问题"。

### sidecar 验证（Python 项目，2026-05-19）

为了验证参考项目对简单项目是否同样有效，用 sidecar（纯 Python + uv + PG）做了第三次 A/B 测试。

| Agent | 策略 | 耗时 | 结果 |
|-------|------|------|------|
| A | 无参考 | ~5min+（未收敛） | 卡在 DID 容器 pip3 问题上 |
| B | 附 dredge-lxk + buyer-center 踩坑记录 | ~3min ✅ | 零卡点收敛 |

同样模式：B 知道 pip3 缺失不是阻塞项（uv 全覆盖），A 却花时间 `apt-get install python3-pip`。

### 跨项目对比

| 项目 | 复杂度 | A（无参考） | B（有参考） | 差距 |
|------|--------|-----------|-----------|------|
| dredge-lxk | Java 8 + CK + 子模块 | ~50min ❌ | ~7min ✅ | ~7x |
| buyer-center | Java 21 + 仅 PG | ~50min+ ❌ | ~7min ✅ | ~7x |
| sidecar | Python + uv 仅 PG | ~5min+ ❌ | ~3min ✅ | ~2x |

### 核心洞察

**参考项目不帮 agent 变快，而是帮 agent 判断"什么值得做"。** 具体来说：

1. **跳过已知坑** — agent 知道 mise 权限、JAVA_HOME、.m2 所有权等是已知环境问题，直接修，不 debug
2. **区分阻塞 vs 非阻塞** — B 知道 pip3 缺失不影响流程；A 却花 2min 装 pip3
3. **知道什么时候放弃** — 测试失败时 B 先 truncate 重跑（参考项目提示非幂等），A 读源码 debug
4. **简单项目差距缩小** — 项目越简单，参考价值越小（sidecar 只差 ~2x vs dredge-lxk 的 ~7x）

**Manager 最值钱的能力不是替 agent 干活，而是告诉它哪些坑值得踩、哪些不用。**

### Manager 模式的改进空间

1. **参考项目池**：每次 onboarding 完成后把踩坑记录加入参考池，下一个项目受益
2. **Agent prompt 标准化**：Manager 的 prompt 应包含：参考项目链接、已知坑列表、项目差异提示
3. **DID 容器限制**：Round 3 DID 验证对复杂项目（Maven + DB）过于耗时，可以考虑只在简单的 Docker 场景下做 DID 验证
4. **超时机制**：agent 在某个 Round 停留超过一定时间，Manager 应介入指导
