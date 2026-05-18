# kyb 项目 onboarding 流程设计

为历史项目接入 kyb 沙箱的标准初始化流程。目标：通过多轮迭代收敛，产出可被 AI agent 非交互式执行的 `.kyb.md`。

## 工作流概览

```
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

### `.kyb.md` 最终模板（v3 — 平衡版）

`````markdown
# .kyb.md — <Project>

<一句话：项目用途、技术栈、关键依赖>

## 关于本文档

**分层**：工具层（JDK/Maven/缓存 volume）→ 依赖层（Nexus/子模块）→ 数据层（DB/migration/codegen）→ 项目层（构建/测试）。下层问题优先抽象复用，上层问题记入项目专属节。
**闭环**：每步执行 → 观察输出 → 判断 → 调整 → 再执行。失败时查踩坑记录（利用已有反馈），修复后更新文档（你的新观测成为后续反馈输入）。
**收敛标准**：连续两轮零新卡点、零歧义、他人 agent 一次通过时收敛。新增依赖则启动新一轮。

> **Agent**：按完整流程逐步骤执行，每步验证预期输出。
> **人类**：直接看 Quick Start。
> **新依赖**：按流程再跑一轮，新增的卡点和缓存信息记入对应章节。

## 预装状态

kyb-base 已预装：Maven ✅ | settings.xml(Nexus含SNAPSHOT) ✅ | 自动chown ✅
需手动装：Java（`mise install java@graalvm-community-21`，~2min冷启动）

## Quick Start（热启动）

```bash
kyb create <project>-<branch>
mise install java@graalvm-community-21                 # 如需（含代理）
cd ~/projects/<project> && export <JDBC_URL等> && mvn test
```

## 完整流程

### 1. 工具确认
```bash
psql -U postgres -c 'SELECT 1'                   # → 1
java -version                                     # → openjdk 21.0.2
mvn --version | head -1                           # → Apache Maven 3.9.x
```

### 2. 子模块（如有）
```bash
# 在 worktree 目录 init，然后 docker cp 到容器
cd ~/.kyb/worktrees/<project>/kyb-<project>-<branch>
git submodule update --init --recursive
docker cp <子模块路径>/. <容器名>:/home/dev/projects/<project>/<子模块>/
```

### 3. 数据库
```bash
psql -U postgres -c "CREATE DATABASE <db>;"
# 数据库名必须与 jOOQ codegen POM 配置一致
cd <子模块目录> && MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25 upgrade
```

### 4. 编译
```bash
cd ~/projects/<project> && export <环境变量> && mvn compile
# → BUILD SUCCESS（首次冷启动 ~3min，热 ~20s）
```

### 5. 测试
```bash
mvn test
# → BUILD SUCCESS（集成测试缺外部服务可能挂起，模块可跳过）
```

### 6. 启动（可选）
```bash
# 启动服务 + curl 健康检查
```

## 冷启动 / 缓存初始化

| 资源 | 缓存方式 | 自动? | 冷启动方式 | 耗时 |
|------|---------|-------|-----------|------|
| Maven 依赖 | `kyb-maven-cache` | ✅ | 首次 mvn 自动下载 | ~3min |
| JDK | `kyb-mise-cache` | ✅ | `mise install java@graalvm-21` | ~2min |
| Git 子模块 | 项目目录 | ❌ | worktree init + docker cp | ~15s |
| PostgreSQL 库 | 容器内 pg data | ❌ | createdb + mig25 upgrade | ~10s |
| jOOQ codegen | `target/generated-sources/` | ❌ | mvn compile 自动触发 | 含在编译中 |

## 踩坑记录

| # | 问题 | 现象 | 原因 | 修复 | 所属层 |
|---|------|------|------|------|--------|
| 1 | ... | ... | ... | ... | 工具/依赖/数据/项目 |

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

## Round 4 — 他人（agent）验证

### 方法

1. 创建一个用于验证的临时分支并创建容器：
   ```bash
   git checkout -b kyb-onboarding-verify
   git push origin kyb-onboarding-verify
   kyb create <project>-kyb-onboarding-verify
   kyb enter <project>-kyb-onboarding-verify
   ```

2. Agent 进入后只读项目 `.kyb.md`，**不依赖其他对话历史**，自行执行。

3. 如果 agent 在某步卡住，收集卡点：
   - 在哪个命令卡住
   - agent 的解读和实际执行的偏差
   - 文档中缺少什么信息

4. 根据卡点修 `.kyb.md`，然后回到 Round 3 重新 replay。

### 通过标准

另一个 agent 在全新容器中，非交互式执行 `.kyb.md`，全流程通过率 100%。

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

#### 收敛结论

三轮（3 个项目）后：
- **工具层卡点已收敛**（3 个，全部于 buyer-server 发现，后续项目只复用无新增）
- **数据层/项目层卡点**每个项目不同，属于项目特有的集成测试和配置问题，需在 `.kyb.md` 中记录但不需改 kyb

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
