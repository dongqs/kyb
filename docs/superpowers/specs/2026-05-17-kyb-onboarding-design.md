# kyb 项目 onboarding 流程设计

为历史项目接入 kyb 沙箱的标准初始化流程。目标：通过多轮迭代收敛，产出可被 AI agent 非交互式执行的 `.kyb.md`。

## 工作流概览

```
最终目标：任何人（人或 agent）拿到 .kyb.md → 按文档顺序逐步骤执行 → 零卡点零歧义一次通过 → 项目在本地拉起来

宿主机                        kyb 容器                   项目 repo
─────                        ────────                   ─────────
git clone 项目                 kyb create                  (空)
kyb build                    进入容器
                             │
                 ┌── Round 1 ──────────────────────────────┐
                 │  手动探索完整流程                        │
                 │  agent 辅助，每步记录成功/失败/修复       │
                 │  重点关注缓存冷/热状态                   │
                 └──────────────────────────────────────────┘
                                        │
                 ┌── Round 2 ───────────▼──────────────────┐
                 │  形式化为 .kyb.md                       │──→ MR → 合并
                 │  含热启动/冷启动两条路径                 │
                 └──────────────────────────────────────────┘
                                        │
                 ┌── Round 3 ───────────▼──────────────────┐
                 │  自 replay 验证                         │
                 │  删容器 → 新 worktree → 照文档重跑      │
                 │  发现歧义/卡点 → 立即修文档             │
                 └──────────────────────────────────────────┘
                                        │
                 ┌── Round 4 ───────────▼──────────────────┐
                 │  他人（agent）验证                      │
                 │  另一 agent 非交互式执行 .kyb.md        │
                 │  卡住 → 回 Round 3 修                   │
                 └──────────────────────────────────────────┘
                                        │
                                    ✅ 收敛
                                    .kyb.md 终版
                                    kyb 改进 MR（如有）
```

## 前置条件

| 条件 | 说明 |
|------|------|
| 宿主机已 clone 项目 repo | `git clone` 到 config.yml 指定路径 |
| `kyb build` 已执行 | `kyb-base:latest` 镜像存在 |
| 项目已加入 `~/.config/kyb/config.yml` | 至少含 `path` 和 `base_branch` |
| PostgreSQL 在容器内可用 | 基础镜像自带的 pg 16 |

## Round 1 — 手动探索

### 1.1 创建沙箱

```bash
kyb create <project>-<branch>
```

成功后记录：
- 容器名
- 创建耗时
- 首次启动耗时（从 `docker run` 到 `settings.json` 就绪）
- `entrypoint.sh` 自动安装的依赖（npm/bundle 等）

### 1.2 从零到测试：完整路径

> **先看 CI，不要猜。** 项目根目录的 `.gitlab-ci.yml`（或其他 CI 配置）是依赖的权威来源。执行前先扫一遍：
> - `services:` 块 → 声明了哪些外部服务（PostgreSQL、Kafka、Redis 等）
> - `variables:` 块 → 环境变量、DSN、Nexus 凭据名
> - `cache:` 块 → 缓存路径
> - `before_script:` 块 → 安装了什么工具（mig25、codegen 等）
> - `image:` 块 → CI 用的构建镜像（本地需手动安装的工具对照参考）
>
> 从 CI 可以直接确定：DB 名、service hostname、工具版本、凭据变量名。不需要从代码里翻。

按以下阶段顺序执行，**每步格式**：

````
## 步骤 X: <动作描述>

### 执行
```bash
<命令>
```

### 结果
✅ 成功 / ❌ 失败（首次尝试）
✅ 成功 / ❌ 失败（修复后）

### 失败原因
...

### 修复方式
...

### 耗时
- 热启动（有缓存）：X 秒
- 冷启动（无缓存）：Y 秒
````

#### 阶段列表

| 阶段 | 验证命令 | 说明 |
|------|---------|------|
| 1. 基础环境 | `psql -U postgres -c 'SELECT 1'` | PostgreSQL 运行 + mise 激活 |
| 2. 项目依赖 | 子模块初始化、语言级 deps | Gradle/Maven/npm/bundle |
| 3. 数据库初始化 | `createdb` + `mig25 upgrade` | 建库 + migration |
| 4. 代码生成 | codegen（如有） | 如 `mig25-codegen generate` |
| 5. 编译 | `./gradlew compileKotlin` | 编译检查 |
| 6. 测试 | `./gradlew test` | 单元测试 |
| 7. 启动服务 | 启动 dev mode | 服务监听端口 |
| 8. API 验证 | `curl` 健康检查或业务接口 | 服务可用性 |

### 1.3 缓存热/冷记录

对每种关键资源，记录两个状态的耗时：

| 资源 | 缓存方式 | 热判断条件 | 冷初始化方式 |
|------|---------|-----------|------------|
| Gradle wrapper + 依赖 | `kyb-gradle-cache` volume | `~/.gradle/wrapper/dists` 非空 | 首次 `./gradlew` 自动下载 |
| Maven 依赖 | `kyb-maven-cache` volume | `~/.m2/repository` 非空 | 首次 `mvn` 自动下载 |
| mise toolchain | `kyb-mise-cache` volume | `~/.local/share/mise/downloads` 非空 | `mise install <tool>@<ver>` |
| mig25_codegen 产物 | 项目目录内 `build/generated/` | 目录存在 | `mig25-codegen generate` |
| PostgreSQL 数据库 | 容器内 pg data | 库存在 | `createdb` + `mig25 upgrade` |
| 镜像层（基础镜像） | Docker 镜像缓存 | `kyb-base:latest` 存在 | `kyb build` |
| 镜像层（项目镜像） | Docker 镜像缓存 | `kyb-<project>:latest` 存在 | 自动构建 |
| 子模块 | `~/.gitmodules` | `.git/modules` | `git submodule update --init` |

### 1.4 卡点记录

每遇到一个错误，记录：
1. 错误现象（完整日志）
2. 根因分析
3. 修复方式
4. 能否通过 kyb 层面的改进（entrypoint/cache volume/镜像）避免

## Round 2 — 形式化为 `.kyb.md`

### 核心理念：`.kyb.md` 是自描述的

`.kyb.md` 不只是记录"这个项目怎么跑"，它本身就是一个**可以独立迭代的方法论文档**：

- **脱离 kyb 也能读**：即使不熟悉 kyb 的读者/agent，也能按文档把项目跑起来
- **不仅是 onboarding**：新增复杂依赖（加 DB、加缓存、加子模块）后，同样可以按这个流程更新文档
- **agent 可自我迭代**：任何一个 agent 读了这个文档，都能按流程执行并更新它
- **自包含**：文档包含了找最优路径的方法，不需要外部流程文档来指导

这意味着 `.kyb.md` 的模板要在第一屏就告诉读者"这篇文档怎么用的"。

### 设计原理

#### 系统论：分层抽象

项目环境从下到上分为多层，每层独立关注、逐步固化：

- **工具层**：运行时（JDK、Maven、Gradle、Node）、Docker 镜像、缓存 volume
- **依赖层**：项目自身的依赖管理（Nexus、子模块、npm、bundle）
- **数据层**：数据库、migration、codegen 产物
- **项目层**：项目特定的构建、测试、启动流程

**Agent 元操作**：每遇到一个卡点，判断它属于哪一层。下层的问题（工具/依赖）抽象成可复用模式，沉入 kyb 或本文档的通用章节。下层稳固后上层自然更快收敛。

#### 控制论：闭环反馈

每轮迭代构成完整控制回路：

```
执行（Run command） → 观察（Check output） → 判断（Analyze result）
       ↑                                        ↓
       └──────── 调整（Fix） ← 决策（Decide）
```

Round 1-4 各是一轮闭环，每轮的输出反馈到下一轮的输入。当连续两轮零新卡点、零歧义时，系统收敛。

**Onboarding agent 使用方式**（有 docker sock，全栈可修）：按完整流程逐步骤执行。每步失败时：
1. 判断卡点所属层（工具/依赖/数据/项目/容器/kyb/宿主机）
2. 查 `踩坑记录` 是否有已知修复（利用已有反馈）
3. 如果没有，修复对应层并更新文档
4. 修复后回到上一步继续执行

**Verification agent 使用方式**（无 docker sock，只读验证）：按完整流程逐步骤执行。卡住说明 `.kyb.md` 有误，反馈给 onboarding agent 修。

### `.kyb.md` 最终模板（v3 — 平衡版）

`````markdown
# .kyb.md — <Project>

<一句话：项目用途、技术栈、关键依赖>

## 设计原理

本文档按**系统论**（分层抽象）和**控制论**（闭环反馈）两个原理组织。

**分层**（每步标注所属层）：
`[工具层]` 运行时/JDK/构建工具/缓存 → `[依赖层]` 仓库/子模块/包管理 → `[数据层]` DB/migration/codegen → `[项目层]` 构建/测试
→ 每步失败时先查对应层的踩坑记录

**闭环**（每步格式 = 执行→观察→判断→调整）：
```
执行命令 → 检查预期输出 → ✅ 继续 / ❌ 查本层排查指引 → 修复后重试
```

**收敛标准**：连续两轮零新卡点、零歧义、他人 agent 一次通过时收敛。新增依赖则启动新一轮。

> **Onboarding agent**（有 docker sock，全栈可修）：按完整流程逐步骤执行，遇到卡点判断所属层→修复→继续。
> **Verification agent**（无 docker sock，只读验证）：按完整流程逐步骤执行，卡住说明文档有误。
> **人类**：直接看 Quick Start。
> **新依赖**：按流程再跑一轮，新增的卡点和缓存信息记入对应章节。

## 预装状态

kyb-base 已预装：Maven ✅ | settings.xml(Nexus含SNAPSHOT) ✅ | 自动chown ✅
需手动装：Java（`mise install java@graalvm-community-21` + `mise use -g`，~2min冷启动）

⚠️ `mise install` 后需 `mise use -g` 激活，否则命令找不到。

## Quick Start（热启动）

```bash
kyb create <project>-<branch>
https_proxy=http://host.orb.internal:2080 mise install java@graalvm-community-21
mise use -g java@graalvm-community-21
# 以下按需
cd ~/projects/<project> && pip3 install mig25 mig25-codegen
psql -U postgres -c "CREATE DATABASE <db>"
MIG25_DSN="..." mig25 upgrade
MIG25_DSN="..." mig25-codegen generate
export <NEXUS_USER等> && mvn test
```

## 外部服务依赖

| 服务 | 项目需要? | CI 有? | 本地/ DID 有? | 说明 |
|------|---------|--------|-------------|------|
| PostgreSQL | ✅ | ✅ | ✅（kyb-base） | `pg_isready` 检查，DID 需手动启 |
| Kafka | 按项目 | 可能 | ❌ | CI 用 `kafka-native` service，DID 缺。Agent 先探测 `kafka:9092`，决定回退策略 |
| RocketMQ / Redis | 按项目 | 可能 | ❌ | 同 Kafka |

Agent 启动前先探测可用服务，根据结果决定完整流程或降级方案。

## Agent 启动前检查

```bash
pg_isready                                           # → accepting connections（否则 pg_ctlcluster 16 main start）
su - dev -c "java -version"                          # → 21.0.x（否则 mise install + mise use -g）
pip3 --version                                       # → 可用（root 下需 su - dev）
# 外部服务
curl -s kafka:9092 >/dev/null 2>&1 && echo "Kafka OK"
```

## 完整流程

> 每步格式：**执行** → **观察**（检查预期输出）→ **判断**（✅ 继续 / ❌ 查对应层排查指引）

### 1. 工具确认 [`工具层`]

```bash
psql -U postgres -c 'SELECT 1'                   # → 1 ✅ | ❌ 启 PG
java -version                                     # → openjdk 21.0.2 ✅ | ❌ mise install + mise use -g
mvn --version | head -1                           # → Apache Maven 3.9.x
```
**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| `java: not found` | 未安装/未激活 | `mise install` + `mise use -g` |
| PG 连不上 | 服务未启 | `pg_ctlcluster 16 main start` |

### 2. 子模块 [`依赖层`]

```bash
cd ~/projects/<project> && git submodule update --init --recursive
# → 子模块目录非空 ✅ | ❌ 查嵌套 submodule
```
**❌ 排查**：嵌套 submodule → 加 `--recursive`

### 3. 数据库 [`数据层`]

```bash
psql -U postgres -c "CREATE DATABASE <db>;"
# → CREATE DATABASE ✅ | ❌ 确认 PG 运行

MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25 upgrade
# → 全部执行完毕 ✅ | ❌ 查 m25.yml 配置
```
**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| DB 名不匹配 | POM 硬编码 | 查 CI `POSTGRES_DB` |
| mig25 找不到迁移 | 目录配置 | 确认 `m25.yml` 中 `dir` |

### 4. 编译 [`工具层` / `项目层`]

```bash
cd ~/projects/<project> && export <凭据> && mvn compile
# → BUILD SUCCESS ✅ | ❌ 见排查（冷 ~3min / 热 ~20s）
```
**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| `Could not resolve` 依赖 | Nexus 凭据 | 设 `ORG_GRADLE_PROJECT_nexusUser/Password` |
| 编译错误 | 项目代码 | 检查具体报错 |

### 5. 测试 [`项目层`]

先探测外部服务：
```bash
curl -s kafka:9092 >/dev/null 2>&1 && echo "OK" || echo "不可用，降级"
```

```bash
cd ~/projects/<project> && mvn test
# → BUILD SUCCESS ✅ | ❌ 缺外部服务时部分测试挂起
```

### 6. 启动（可选）
```bash
# 启动服务 + curl 健康检查
```

## 冷启动 / 缓存初始化

| 资源 | 缓存方式 | 自动? | 踩坑探索耗时 | 等待耗时（冷→热） | 冷启动方式 |
|------|---------|-------|------------|-------------------|-----------|
| JDK | `kyb-mise-cache` | ❌ | ~5min（代理配置错） | 2min→0s | `mise install java@...`（注意代理模式） |
| Gradle/Maven 依赖 | shared volume | ✅ | ~3min（Nexus 凭据） | 3min→~10s | 首次构建自动下载 |
| Git 子模块 | 项目目录 | ❌ | ~1min（嵌套 submodule） | ~15s→0s | `git submodule update --init --recursive` |
| PostgreSQL 库 | 容器内 pg data | ❌ | ~2min（DB 名不确定） | ~30s→~30s | `createdb` + `mig25 upgrade` |
| Codegen | `build/generated/` | ❌ | ~1min（配置项） | ~60s→~60s | `mig25-codegen generate` |
| PostgreSQL 启动 | 容器内 | ❌ | ~1min（DID 不自启） | 3s→3s | `pg_ctlcluster 16 main start` |

## 踩坑记录

| # | 问题 | 现象 | 原因 | 修复 | 所属层 |
|---|------|------|------|------|--------|
| 1 | ... | ... | ... | ... | 工具/依赖/数据/项目 |

## 按层快速排查

| 所属层 | 常见失败 | 排查入口 |
|--------|---------|---------|
| **工具层** | JDK 未激活、Nexus 凭据、缓存权限、服务未启动 | 踩坑记录（工具层条目） |
| **依赖层** | 子模块为空、嵌套 submodule、包下载失败 | 踩坑记录（依赖层条目） |
| **数据层** | migration 找不到、codegen 不匹配 | 踩坑记录（数据层条目） |
| **项目层** | 测试失败（缺外部服务、代码错误） | 踩坑记录（项目层条目） |

## 本项目卡点汇总

- **kyb 工具待改进**：需要改 kyb 本身的
- **环境依赖**：需要宿主机配合的（数据库、代理等）
- **项目自身**：项目代码/配置问题（如 jOOQ JDBC 名、集成测试挂起）

## 迭代记录

| 轮次 | 耗时 | 变化 |
|------|------|------|
| Round 1 手动探索 | ~Xmin | 发现 N 个卡点 |
| Round 2 形式化 | — | 修复不一致，固化文档 |
| Round 3 自 replay | ~Ymin | Z 倍提升 |
| Round 4 他人验证 | ~Ymin | 零歧义一次通过 |
`````
| Round 3 | ~Ymin | 缓存热后 Z 倍 |

## kyb 改进需求

- [ ] ...
`````

### 写作原则

- **每条命令可独立复制粘贴执行**，不含歧义
- **失败路径也写**："如果 X 报错，执行 Y"
- **冷/热路径分开**，明确判断条件
- **每个步骤含预期输出**，方便 agent 校验
- **异步操作后加 wait/retry**：服务启动、端口监听等操作不能假定即时完成，应写 `sleep N` 或 `retry until` 模式
- **路径全用绝对路径**，避免 `cd` 隐含状态
- **分层记录卡点**：每步失败时，判断是工具层/依赖层/数据层/项目层的哪一层问题。下层问题优先抽象复用，上层问题记入项目专属节
- **闭环记录**：每个坑必须包含"现象 → 原因 → 修复 → 是否可预见/可预防"的完整链条。修复后验证再继续
- **文档本身也可迭代**：新问题出现时，按流程再跑一轮，更新对应章节。`kyb 待改进` 的条目是待办，不是缺陷
- **区分操作耗时、等待耗时、探索耗时**：冷启动表同时记录踩坑探索耗时（排查试错时间）和执行等待耗时。后续收敛目标是探索耗时归零
- **声明外部服务依赖**：在项目描述节列出 Kafka / RocketMQ / Redis 等外部服务，注明 CI 有/无、本地有/无。agent 执行前先探测可用服务决定策略
- **mise install 后需激活**：`mise install <tool>` 只下载安装，不激活。必须加 `mise use -g <tool>` 或 `mise use <tool>` 将其加入配置
- **先看 CI，不要猜**：`.gitlab-ci.yml` 是依赖的权威来源。services→外部服务、variables→环境变量/凭据、before_script→工具、image→构建镜像。先扫一遍再动手，避免瞎猜 DB 名、hostname、凭据

## Round 3 — 自 replay 验证

### 流程

```bash
# 1. 清理旧容器
kyb rm <project>-<branch>

# 2. 删除旧 worktree（如需）
cd <project-path>
git worktree prune

# 3. 按 .kyb.md 重建
kyb create <project>-<branch>
kyb enter <project>-<branch>
```

### 校验标准

- `.kyb.md` 中每条命令可在新容器中原样执行
- 无隐含步骤（"上一步已配好的不用再配"这类假设）
- 冷启动路径每步都能跑通
- 错误处理分支覆盖主要失败场景

### 修正循环

```
发现歧义 → 修 .kyb.md → 删容器重建 → 再跑 → 直到无卡顿
```

## 最终目标

> **任何人（人或 agent）拿到 `.kyb.md`，按文档顺序逐步骤执行，零卡点、零歧义、一次通过，即可把项目在本地拉起来。**
>
> 卡点 = 执行不下去、需要外部知识、命令报错不明确。歧义 = 文档没说清楚用哪个值、哪条路径、哪个用户。
>
> 收敛标准：连续两轮零新卡点（含他人一次通过）。此后新增依赖 → 启动新一轮。

## Round 4 — 他人（agent）验证

### 准备工作

1. 创建一个用于验证的临时分支并创建容器：
   ```bash
   git checkout -b kyb-onboarding-verify
   git push origin kyb-onboarding-verify
   kyb create <project>-kyb-onboarding-verify
   kyb enter <project>-kyb-onboarding-verify
   ```

2. **确认容器状态**：PG 是否运行、项目代码是否在 `/home/dev/projects/<project>`、`.kyb.md` 是否存在。

### 验证 agent prompt 模版

```markdown
你是一个验证 agent，任务是检验 <project> 项目的 .kyb.md 文档质量。

## 环境
你在一个 kyb DID 容器内。PostgreSQL 已启动。项目代码在
`~/projects/<project>`，`kyb-onboarding-verify` 分支已检出。

## 任务
1. 只读 `~/projects/<project>/.kyb.md`，不依赖任何其他对话历史
2. 严格按照文档步骤逐条执行
3. 每步记录：执行结果（成功/失败），如果卡住记录在哪句话卡住、为什么
4. 完成时报告：总共几步、几步成功、几步失败、文档问题清单

## 执行方式
所有命令通过 `docker exec <容器名> bash -c '...'` 执行。
注意 dev 用户的 mise 环境需 `eval "$(mise activate bash)"` 激活。
pip3 在 dev 用户下可用，root 需 `su - dev -c`。
```

### 执行与反馈

3. Agent 进入后只读项目 `.kyb.md`，**不依赖其他对话历史**，自行执行。

4. 如果 agent 在某步卡住，收集卡点：
   - 在哪个命令/哪句话卡住
   - agent 的解读和实际执行的偏差
   - 文档中缺少什么信息

5. 根据卡点修 `.kyb.md`，然后回到 Round 3 重新 replay。

### 通过标准

另一个 agent 在全新容器中，非交互式执行 `.kyb.md`，全流程通过率 100%。

> **经验**：triggers-refund 的 Round 4 实测，agent 按文档全流程一次通过（零卡点），仅发现文档描述与实际数据的偏差（migration 数量过时、codegen 体积不准）。这些问题不影响执行，但建议修复以保持文档准确。

## 产出物清单

| 产出 | 位置 | 状态 |
|------|------|------|
| `.kyb.md` | 项目 repo 根目录 | 合并后永久有效 |
| 缓存 volume | 宿主机（Docker named volume） | 持久化，不随容器删除 |
| kyb 改进 MR | kyb repo | 可选，通用化改进 |
| smoke.sh 条目 | kyb repo `test/smoke.sh` | 可选，CI 集成 |

## kyb 项目自身的 `.kyb.md`

kyb 项目根目录也放一个 `.kyb.md`，作用是**防走错 + 指引**：

- 告诉读者"这是 kyb 工具仓库，不是被管理的业务项目"
- 指引去具体项目找 `.kyb.md`
- 如果项目还没有 `.kyb.md`，用上面的模板创建一个并发 MR

内容约 5-10 行，不包含任何项目 onboarding 细节。参见 kyb 仓库根目录的 `.kyb.md`。

## 附录：标准检查清单

创建容器后，按顺序检查：

- [ ] PostgreSQL 运行正常
- [ ] mise 已激活且 toolchain 版本正确
- [ ] Git submodule 已初始化（如有）
- [ ] `~/.config/kyb/config.yml` 可读
- [ ] Glab 已配置
- [ ] Gradle/Maven 缓存 volume 已挂载
- [ ] 缓存 volume 内容是否正确
- [ ] 数据库可创建
- [ ] Migration 可执行
- [ ] 编译通过
- [ ] 测试通过
- [ ] 服务可启动
- [ ] API 可访问

## 参考案例：buyer-server 首次 onboarding 实测

### 项目概况

- Java 21 + Maven 多模块 + PostgreSQL + jOOQ codegen + 3 个 git 子模块
- 父 POM `com.leyantech:base:2.0.0-SNAPSHOT` 在公司内网 Nexus，含 SNAPSHOT
- CI 流程：PostgreSQL service → mig25 → mvn test → Sonar

### 架构要点

Maven 多模块，8 个子模块：
- `buyer-common`（含 jOOQ codegen，依赖数据库 schema）
- `buyer-server-web`（含单元测试）
- `buyer-service` / `buyer-service-consumer` / `buyer-job-service` / `buyer-infra-service`
- `assemble`（打包）

3 个 git 子模块，各自有独立数据库和 mig25 migration。

### 完整耗时（冷启动）

| 阶段 | 耗时 | 说明 |
|------|------|------|
| git clone | ~30s | SSH，内网 |
| git submodule init | ~15s | 3 个子模块 |
| kyb create | ~20s | 含 worktree + docker run + 初始化 |
| PostgreSQL 启动 | 自动 | entrypoint.sh |
| mise install maven@3.9.9 | ~30s | 需要 ALL_PROXY |
| 建库 + mig25 | ~10s | 3 个数据库 |
| mvn compile（首次） | 2m15s | 含依赖下载 + jOOQ codegen |
| mvn test（首次） | 1m02s | with warm Maven cache |

### 发现的卡点

1. **子模块内容为空** — `docker cp` 不解析 git worktree 的子模块文件。需在宿主机 worktree 中先 `git submodule update --init --recursive`，再 `docker cp`

2. **Maven 未预装** — 基础镜像有 GraalVM JDK 21 和 Gradle，但没有 Maven。需要 `mise install maven@3.9.9`（且需代理加速）

3. **Nexus 不解析 SNAPSHOT** — Mirror `maven-public` 默认只开 releases。需要在 `settings.xml` 显式加入 SNAPSHOT 启用的 profile

4. **数据库名不匹配** — jOOQ POM 硬编码 `pinduoduo_buyer`/`doudian_buyer`，直接建 `pdd_buyer`/`dy_buyer` 报错。建库名必须与 POM 一致

5. **Maven .m2 权限问题** — `kyb-maven-cache` volume 首次挂载时部分目录属主为 root。需要 `chown -R dev:dev ~/.m2/repository`

### 对 kyb 的改进建议

- 基础镜像预装 Maven（或加入到 mise config）
- 基础镜像预配 Maven 的 Nexus settings.xml（含 SNAPSHOT）
- `kyb create` 的 DinD 模式自动处理子模块初始化
- 增加 `kyb config` 子命令绕过 `:ro` 限制

### Round 3 实测对比：冷启动 vs 热启动

经过 Round 1（手动探索）→ Round 2（形式化）→ Round 3（自 replay），实测 buyer-server 的收敛数据：

| 阶段 | Round 1 冷启动 | Round 3 热启动 | 提升 |
|------|---------------|---------------|------|
| mise install maven | ~30s | 8.4s（mise cache 热） | 3.6x |
| 子模块 init | ~25s（手工） | **自动就绪** | 省去 |
| 建库 + mig25 | ~20s | 2.5s | 8x |
| mvn compile | 2m15s（冷） | **12.6s**（Maven cache 热） | **10.7x** |
| mvn test | 1m02s | **20.7s** | 3x |
| **总计** | **~5min** | **~1min** | **5x ↑** |

**关键发现：**
- `kyb-maven-cache` 和 `kyb-mise-cache` 是共享 named volume，`kyb rm` 不会删除。后续容器秒级复用
- 子模块 `.git/modules` 在主 clone 中持久化，跨 worktree 共享。仅首次需要手动 `submodule update --init`
- 文档固化后无歧义，严格按 `.kyb.md` 重跑一次通过，零卡点

### 跨项目验证：nova（第二项目）

Nova 是第 2 个走完 onboarding 流程的项目，验证了跨项目鲁棒性：

**从 buyer-server 继承的解决方案（3 项）：**
1. Maven 走代理安装
2. Nexus SNAPSHOT settings.xml 配置
3. `.m2/repository` 权限修复（`chown`）

**新发现的跨项目问题（1 项）：**
- `kyb-maven-cache` 共享 volume 的权限问题：buyer-server 写入的缓存文件的属主是 root，nova 读不了。每次 `kyb create` 后需 `chown`
- **根因**：`docker run` 时创建 volume 并挂载，首次写入时容器进程以 root 运行某些步骤

**nova 特有发现：**
- 依赖集不同，首次编译需下载 nova 特有的依赖（5min），比 buyer-server（2min15s）更久
- 无子模块、无本地 codegen，比 buyer-server 简单

**结论：** 跨项目复用了 3 个已有方案，新增 0 个方案（权限问题已在 buyer-server 记录）。
鲁棒性从"只覆盖 buyer-server"扩展到"覆盖 Maven + Nexus 类项目"。

### 三项目收敛：data-ant（第三项目，最复杂）

#### 项目概况

19 Maven 模块 + 5 个子模块（含嵌套子模块） + 6 个 PostgreSQL 数据库 + jOOQ codegen（多 schema） + RocketMQ + Redis。内部 Nexus 发布 JAR 包。

#### 跨项目继承

| 继承项 | 来源 | data-ant 状态 |
|--------|------|-------------|
| Maven 安装 + 代理 | buyer-server | ✅ 直接复用 |
| Nexus SNAPSHOT settings.xml | buyer-server | ✅ 直接复用 |
| `.m2/repository` chown | buyer-server | ✅ 直接复用 |
| 子模块 worktree init + docker cp | buyer-server | ✅ 直接复用（5 子模块含嵌套） |
| jOOQ JDBC_URL 环境变量 | buyer-server | ✅ 扩展为 6 个 URL |

#### 新发现

| # | 问题 | 所属层 | 说明 |
|---|------|--------|------|
| 1 | jOOQ codegen 多 schema（data_ant + feisuo） | 数据层 | 项目特有，JDBC_URL 注入解决 |
| 2 | 集成测试挂起（ConcurrencyWebHandler） | 项目层 | 缺外部 HTTP 服务，需 CI 或 mock |
| 3 | 子模块含嵌套 submodule（Norland/party） | 依赖层 | `--recursive` 标志解决 |

#### 三项目卡点收敛矩阵

| 卡点 | buyer-server | nova | data-ant | 分类 |
|------|:-----------:|:----:|:--------:|------|
| Maven 未预装 | ✅ 发现 | ✅ 复用 | ✅ 复用 | **工具层 → 改 kyb** |
| Nexus SNAPSHOT | ✅ 发现 | ✅ 复用 | ✅ 复用 | **工具层 → 改 kyb** |
| 共享 volume 权限 | ✅ 发现 | ✅ 再发现 | ✅ 再发现 | **工具层 → 改 kyb** |
| 子模块 docker cp | ✅ 发现 | N/A | ✅ 复用 | **工具层 → 改进** |
| jOOQ JDBC_URL | ✅ 发现 | N/A | ✅ 再发现 | 数据层（项目级） |
| 数据库名匹配 | ✅ 发现 | N/A | N/A | 项目级 |
| 集成测试挂起 | N/A | N/A | ✅ 发现 | 项目级 |

#### 已上船项目

已完成标准化 onboarding 的项目列表。

| 项目 | 状态 | .kyb.md | R1 总耗时 | R3/R4 热执行 | 探索耗时 | 备注 |
|------|------|---------|-----------|-------------|---------|------|
| buyer-server | ✅ 收敛 | 项目仓库 | ~5min+? | ~1min | 未记录（早期） | 首个 onboarding，发现 Maven/Nexus/子模块卡点 |
| nova | ✅ 收敛 | 项目仓库 | 未记录 | 未记录 | 未记录（早期） | 第二项目，验证跨项目复用 |
| data-ant | ✅ 收敛 | 项目仓库 | 未记录 | 未记录 | 未记录（早期） | 最复杂（19模块+5子模块+6DB），工具层卡点收敛 |
| triggers-refund | ✅ 收敛 | [MR #25](https://git.leyantech.com/base-service/triggers-refund/-/merge_requests/25) | ~30min | ~2min | ~23min | 首个 DID 模式，验证分层模型+双 agent |

### 接入指引

1. 项目加入 `~/.config/kyb/config.yml`
2. 宿主机 `git clone` 项目
3. 从本设计文档的模版创建 `.kyb.md`
4. 跑 Round 1-4
5. 合入 `.kyb.md` MR
6. 更新此表
- **工具层卡点已收敛**（3 个，全部于 buyer-server 发现，后续项目只复用无新增）
- **数据层/项目层卡点**每个项目不同，属于项目特有的集成测试和配置问题，需在 `.kyb.md` 中记录但不需改 kyb

### 跨项目验证：triggers-refund（第四项目，验证 DID 模式）

#### 项目概况

Kotlin 2.3 + Quarkus 3.28 + PostgreSQL 16 + jOOQ codegen + OpenAPI。Gradle 单模块，1 个 git 子模块（`stream`，含嵌套 `party`），依赖内部 Nexus。CI 有 Kafka service。

#### 新增的模板改进

triggers-refund 是首个 `kyb did create`（DID）模式 onboarding 的项目，区别于前三个项目的普通容器模式。新发现：

| # | 问题 | 所属层 | 模板改进 |
|---|------|--------|---------|
| 1 | DID 容器 PG 不自启 | 工具层 | 启动前检查加 `pg_isready` |
| 2 | mise install 后需 `mise use` 激活 | 工具层 | 写作原则加"install 后需激活" |
| 3 | `ALL_PROXY=socks5` 与 mise rustls 不兼容 | 工具层 | Quick Start 用 `https_proxy=http` |
| 4 | 外部服务依赖（Kafka） | 项目层 | 加"外部服务依赖"声明节，agent 先探测 |
| 5 | 探索耗时意义大于操作耗时 | 方法论 | 冷启动表加"踩坑探索耗时"列 |

#### 收敛数据

| 轮次 | 总耗时 | 踩坑探索 | 执行等待 |
|------|--------|---------|---------|
| Round 1 手动探索 | ~30min | ~23min | ~7min |
| Round 3 自 replay | ~7min | 0 | ~7min |
| Round 4 他人验证 | ~4min | 0 | ~4min |

#### 对模版的影响

到第四项目为止，模板已完成 4 轮迭代（buyer-server → nova → data-ant → triggers-refund）。工具层卡点全部收敛，新增的 DID 模式特定问题也已纳入模板。

## kyb 改进需求汇总

基于三个项目的 onboarding 经验，kyb 需要以下改进：

### P1 — 必须改（影响所有项目）

1. **基础镜像预装 Maven** — 加入 `mise.config.toml`，让 `mise install` 在 Docker build 时自动装好 `maven@3.9.9`
2. **预配 Maven Nexus settings.xml** — 在基础镜像中创建 `~/.m2/settings.xml`，含 Nexus 镜像 + SNAPSHOT 支持
3. **共享 volume 权限自动修复** — entrypoint 中 `chown -R dev:dev ~/.m2/repository ~/.gradle`（挂载 volume 后）

### P2 — 建议改（改善体验）

4. **子模块自动初始化** — `kyb create` 在创建容器后检测子模块并 init，或给 agent 的 CLAUDE.md 中提示
5. **jOOQ 项目环境变量注入** — 容器启动时注入常见的 JDBC URL 环境变量（可配置化）

### P3 — 远期

6. **`kyb config` 命令** — 支持从容器内添加/修改项目配置
7. **集成测试沙箱** — 提供 mock 外部服务的测试环境
