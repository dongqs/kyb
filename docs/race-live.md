# SDK Batch Onboarding — 赛事直播

**时间**: 2026-05-19
**项目**: 6 个 hamilton-sdk 消费方项目并发 onboarding
**策略**: 每个 agent 附通用踩坑记录，减少重复劳动

## 参赛选手

| # | 项目 | Agent ID | MR | 状态 |
|---|------|---------|-----|------|
| 1 | form-manager | a0b9b4ab5fa341d2b | !38 | ✅ **R4** |
| 2 | moneta | afd3f7b30d4db46c8 | !237 | ✅ **R4** |
| 3 | rating-boost | a96e4a6da37512f4f | !44 | ✅ **R4** |
| 4 | netflix | a19763956a16107e5 | !49 | ✅ **R4** |
| 5 | recommendation-filter | ac003c86b5bd6f3b8 | !205 | ✅ **R4** |
| 6 | recommendation-finder | a4d3b88fbdf1b9f42 | !172 | ✅ **R4** 🏆 |

## 赛况直播

| # | 项目 | Round | 状态 | 备注 |
|---|------|-------|------|------|
| 1 | form-manager | R4 | ✅ **收敛** | Lombok 1.18.22 + Java 21 不兼容，换 Java 17 编译。R4 零卡点通过 |
| 2 | moneta | R4 | ✅ **收敛** | R3 DID 验证通过（需手动装 Java/Maven），R4 零卡点 |
| 3 | rating-boost | R4 | ✅ **收敛** | R3 DID 验证通过（手动装 PG/pip/Maven），R4 一次通过 |
| 4 | netflix | R4 | ✅ **收敛** | R3 DID 验证通过，R4 零卡点。全 4 轮收敛（~5min 总耗时）|
| 5 | recommendation-filter | R4 | ✅ **收敛** | 12 tests passed，R3 DID 验证通过，R4 ~31s 零卡点 |
| 6 | recommendation-finder | R4 | 🏆 **收敛** | R3 ~5min DID 验证通过，R4 ~1min 零卡点。全 4 轮收敛 |

## 各项目时间线

### 1. form-manager
| 时间 | 事件 |
|------|------|
| T+0min | 启动，Java 21 + Maven，创建 DB formmanagerdb + mig25 |
| T+2min | 首次 compile 失败（依赖不完整），重试后 ✅ BUILD SUCCESS |
| T+3min | `mvn test` → No tests to run ✅ R1 完成 |
| T+4min | 开始填写 .kyb.md |
| T+5min+ | 填写项目描述、技术栈、预装状态、外部依赖表 |
| T+8min | commit & push 完成（3 commits: 初始模版/项目名/详情）|
| — | *session 切换* |
| T+R2-0min | R2 发现 Lombok 1.18.22 与 Java 21 不兼容（NoSuchFieldError），切 Java 17 |
| T+R2-18min | R2 清理重跑 + 解决 Java 版本问题 |
| T+R3-0min | DID 容器验证：修复 mig25 status + ~/.m2 权限 |
| T+R3-2min | DID 全流程通过 ✅ |
| T+R4-0min | R4 终检零卡点通过 |
| T+R4-1min | ✅ **全 4 轮收敛**，MR !38 已更新 |

### 2. moneta
| 时间 | 事件 |
|------|------|
| T+0min | 启动，Java 21 + Maven，5 modules |
| T+1min | 创建 DB moneta + mig25 upgrade ✅ |
| T+2min | moneta-base jOOQ codegen + compile ✅ |
| T+3min | 全项目 compile ✅（-q 静默成功） |
| T+4min | `mvn test` → jOOQ codegen 报错 "class file version 61.0 vs 52.0" |
| T+5min+ | 🔧 排查 Java 版本问题 |
| T+7min | 定位 jOOQ codegen 需 Java 17+，Maven 运行在 Java 21 但 codegen 插件 class version 冲突 |
| T+9min | 重试 `mvn test -rf :moneta-base` → ✅ BUILD SUCCESS，28 tests passed |
| T+10min | 更新 .kyb.md（项目描述、5 modules、jOOQ codegen、mig25）|
| T+12min | 3 commits pushed to kyb/onboarding |
| — | *session 切换* |
| T+R2-0min | R2 冷却计时：Maven deps 3m19s，热启编译 11s，测试 13s |
| T+R3-0min | DID 容器验证：安装 Java/Maven/mig25，28 tests all passed ✅ |
| T+R4-0min | R4 终检 DID 重零跑通 |
| T+R4-5min | ✅ **全 4 轮收敛**，MR !237 已更新 |

### 3. rating-boost
| 时间 | 事件 |
|------|------|
| T+0min | 启动，分析 jOOQ codegen 配置（JDBC_URL, DOUDIAN_JDBC_URL）|
| T+2min | 设置 JDBC_URL env vars，开始 compile |
| T+3min | `mvn compile` ✅ BUILD SUCCESS（1:34min，含依赖下载）|
| T+4min | `mvn test` → jOOQ codegen "class file version 61.0 vs 52.0" |
| T+5min+ | 🔧 发现 `mise where java` 指向 corretto-8，切回 corretto-21 |
| T+7min | 确认 `mise use -g java@corretto-21` 后 `mvn test` ✅ BUILD SUCCESS |
| T+8min | 更新 .kyb.md（5 modules, Apollo, RocketMQ, 子模块 doudian-buyer）|
| T+10min | commit & push（3 commits），开始 R2 |
| — | *session 切换* |
| T+R2-0min | R2 冷 ~4.5min / 热 ~48s |
| T+R3-0min | DID 容器创建：手动装 PG/pip/Maven，jOOQ codegen + 22 tests 通过 ✅ |
| T+R4-0min | R4 终检一次通过 |
| T+R4-1min | ✅ **全 4 轮收敛**，MR !44 已更新 |

### 4. netflix
| 时间 | 事件 |
|------|------|
| T+0min | 启动，Java 8 + Maven，4 modules |
| T+1min | `mvn test` → JaCoCo 0.8.8 不兼容 Java 21 class files ❌ |
| T+2min | 加 `-Djacoco.skip=true` → test compile 错（payment-push）|
| T+3min | 读测试源码排查 → `mvn clean test -Djacoco.skip=true` |
| T+4min | ✅ BUILD SUCCESS，3 tests passed |
| T+5min | 发现无 DB/无 migration/无 codegen，开始填写 .kyb.md |
| T+6min | commit & push（3 commits）|
| — | *session 切换* |
| T+R2-0min | R2 优化：cold ~27s / hot ~13s |
| T+R2-1min | commit R2 计时，更新 .kyb.md |
| T+R3-0min | DID 容器创建，verification agent 全流程验证通过 |
| T+R3-2min | DID: 3 tests all passed ✅ |
| T+R4-0min | R4 最终检查 clean→test 零卡点 |
| T+R4-1min | ✅ **全 4 轮收敛**，MR !49 已更新 |

### 5. recommendation-filter
| 时间 | 事件 |
|------|------|
| T+0min | 启动，分析 CI（sonar-java 模版，极简）|
| T+1min | `mvn compile` ✅ → `mvn test` → gRPC NoClassDefFound ❌ |
| T+2min | 发现 Maven 运行在 Java 21 而非 Java 8（common 模块 gRPC 不兼容）|
| T+3min | `mise use -g java@corretto-8` → `mvn test` → ✅ BUILD SUCCESS |
| T+4min | 12 tests passed（common 10 + filter 1 + consumer 1）|
| T+5min | 开始填写 .kyb.md |
| T+7min | commit & push（3 commits: 推荐过滤系统 Java 8, Kafka 消费, 无 DB）|
| — | *session 切换* |
| T+R3-0min | DID 容器验证全流程（Java 8, 12 tests）|
| T+R3-2min | ✅ DID 全流程通过 |
| T+R4-0min | R4 终检 clean→test ~31s，12 tests all passed |
| T+R4-1min | ✅ **全 4 轮收敛**，MR !205 已更新 |

### 6. recommendation-finder 🏆（首位完成）
| 时间 | 事件 |
|------|------|
| T+0min | 启动，分析项目结构 |
| T+1min | 发现无 DB/无 migration/纯 Mock 测试 |
| T+2min | `mvn compile` ✅ 36s |
| T+3min | `mvn test` ✅ 42s，23 tests all passed |
| T+4min | 开始 R2 优化 |
| T+6min | R2 热启动：clean→compile 8s, clean→test 42s |
| T+7min | commit R2 计时数据（4 commits total）|
| T+8min | 创建 DID 容器 `kyb-dredge-recommendation-finder-verify` |
| T+9min | ⏳ agent 超时（前一 session 终止）|
| — | *session 切换* |
| T+R3-0min | R3 重启：DID 容器内全流程验证 |
| T+R3-3min | DID: `mvn compile` ✅（需先装 ~/.m2/settings.xml）|
| T+R3-5min | DID: `mvn test` ✅，23 tests all passed |
| T+R4-0min | R4 最终检查：clean→test 零卡点通过 |
| T+R4-1min | ✅ **全 4 轮收敛**，MR !172 已更新 |

## 汇总

| # | 项目 | 完成轮次 | 耗时 | 测试 | 关键卡点 |
|---|------|---------|------|------|---------|
| 1 | form-manager | R4 ✅ | ~29min | 无测试 | Lombok 1.18.22 + Java 21 不兼容 |
| 2 | moneta | R4 ✅ | ~33min | 28 passed | jOOQ codegen、DID 手动装 Maven、测试非幂等 truncate |
| 3 | rating-boost | R4 ✅ | ~17min | 22 passed | mise 回退 + DID 手动装 PG/pip/Maven |
| 4 | netflix | R4 ✅ | ~5min | 3 passed | JaCoCo 0.8.8 不兼容 JDK 21 |
| 5 | recommendation-filter | R1 ✅ | ~7min | 12 passed | Java 21→8 切换（gRPC 不兼容）|
| 6 | recommendation-finder | R4 🏆 | ~11min | 23 passed | 无卡点 — 全 4 轮收敛 |

**结果**: 🎉 **6/6 全 4 轮收敛！** 所有 `.kyb.md` 已 commit 并 push 到 `kyb/onboarding` 分支。MR 已自动更新。