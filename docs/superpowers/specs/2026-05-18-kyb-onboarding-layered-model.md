# kyb onboarding 分层模型与双 agent 迭代流程

## 背景

原有 onboarding 分层模型（工具层→依赖层→数据层→项目层）只覆盖了容器内到项目的管道段，不足以描述完整的端到端栈。triggers-refund 实践中发现：

- 卡点可能来自宿主机、网络、容器镜像、运行时、onboarding agent 能力等层
- 在错误的层上解决问题是无效的（如把宿主机代理问题当成容器内工具问题去修）
- 两层 agent（onboarding agent / verification agent）有不同的能力和职责边界
- 每一轮迭代验证的内容不同，需要精确定义

## 完整分层模型

从宿主机到 `.kyb.md`，共 8 层：

```
                    ┌─────────────────────────────────────┐
                    │  宿主机系统及网络                     │
                    │  macOS/Orbstack/代理/DNS/SSH/磁盘    │
                    │  修复：通知人类（agent 够不到）       │
                    └─────────────────────────────────────┘
                                    │
                    ┌───────────────▼─────────────────────┐
                    │  kyb 工具层                          │
                    │  CLI 命令/Docker 编排/配置管理/volume  │
                    │  修复：发 issue / 提 MR               │
                    └───────────────┬─────────────────────┘
                                    │
              ┌─────────────────────▼─────────────────────┐
              │  外圈容器（kyb container）                  │
              │  ┌─────────────────────────────────────┐  │
              │  │ 镜像层（静态）                        │  │
              │  │ Dockerfile / mise 预装 / OS 包       │  │
              │  │ 修复：修改 Dockerfile → kyb build    │  │
              │  ├─────────────────────────────────────┤  │
              │  │ 运行时层（动态）                      │  │
              │  │ entrypoint.sh / volume mount         │  │
              │  │ 环境变量 / 服务启停 / 网络             │  │
              │  │ 修复：改 entrypoint / config          │  │
              │  ├─────────────────────────────────────┤  │
              │  │ onboarding agent                    │  │
              │  │ 有 docker sock，全栈诊断能力           │  │
              │  │ 可修 kyb / 镜像 / 项目 / .kyb.md     │  │
              │  └─────────────────────────────────────┘  │
              └─────────────────────┬─────────────────────┘
                                    │
              ┌─────────────────────▼─────────────────────┐
              │  DID 容器（内圈，Docker-in-Docker）        │
              │  ┌─────────────────────────────────────┐  │
              │  │ DID 镜像层                           │  │
              │  ├─────────────────────────────────────┤  │
              │  │ DID 运行时层                          │  │
              │  ├─────────────────────────────────────┤  │
              │  │ verification agent                   │  │
              │  │ 无 docker sock，只读 .kyb.md          │  │
              │  │ 只能验证文档，不能修任何东西           │  │
              │  └─────────────────────────────────────┘  │
              └─────────────────────┬─────────────────────┘
                                    │
                    ┌───────────────▼─────────────────────┐
                    │  项目代码                            │
                    │  修复：git commit（by onboarding agent）         │
                    └───────────────┬─────────────────────┘
                                    │
                    ┌───────────────▼─────────────────────┐
                    │  .kyb.md 文档                        │
                    │  修复：git commit（by onboarding agent）         │
                    └─────────────────────────────────────┘
```

### 诊断原则

每遇到卡点，按层从下往上排查：

```
卡点现象
  → 是宿主机问题（代理/SSH/磁盘）？ → notify human
  → 是 kyb 工具问题？               → 发 issue
  → 是容器镜像缺东西？               → 改 Dockerfile
  → 是容器运行时配置？               → 改 entrypoint / mount
  → 是 onboarding agent 自身能力？   → 调 prompt / 加上下文
  → 是 DID 容器环境？                → 改 DID 配置
  → 是项目代码问题？                 → git commit 修
  → 是 .kyb.md 不准？               → git commit 修
```

**核心规则：该修 kyb 的不要塞进 .kyb.md 当踩坑记录。该修项目的不要用 onboarding 流程绕过去。**

### 通知人类

遇到 agent 无法处理的层（主要是宿主机层），必须通过 `kyb notify` 通知人类：

| 场景 | 命令 | 说明 |
|------|------|------|
| 全流程跑通（长任务完成） | `kyb notify done "项目名 onboarding 完成，耗时 Xmin"` | 通知人类来检查 |
| 需要人工介入（宿主机/网络/权限） | `kyb notify urgent "需要处理：..."` | 阻塞，等人解决 |
| 确认外部操作（发 issue、改配置等） | `kyb notify blocked "需要确认：..."` | 等人回复后再继续 |

**Agent 应每步执行后判断**：当前卡点是 agent 能修的还是必须找人的。

## 双 agent 模型

| 维度 | onboarding agent | verification agent |
|------|-----------------|-------------------|
| **所在容器** | 外圈 kyb 容器 | 内圈 DID 容器 |
| **docker sock** | 有 | 无 |
| **诊断能力** | 全栈，能判断卡点属于哪一层 | — |
| **修复能力** | 修 kyb / 镜像 / 项目 / .kyb.md | 不能修，只能发现和反馈 |
| **执行场景** | Round 1-2 | Round 3-4 |
| **卡住含义** | 该修某层 | .kyb.md 有误 |

### 关键交互

```
onboarding agent 发现问题
  │
  ├→ 宿主机层 → kyb notify urgent（等人）
  ├→ kyb 工具层 → 发 issue
  ├→ 容器镜像层 → 修 Dockerfile → kyb build
  ├→ 容器运行时层 → 修 entrypoint / config
  ├→ 项目层 → git commit
  ├→ .kyb.md 层 → git commit
  │
  └→ 修完后 → verification agent 验证 → 还卡？回到上层诊断
```

## 四轮迭代流程

### Round 1：先跑通（onboarding agent）

**目标**：从零到测试，全流程跑通一次。

**原则**：
- **不要优化**。卡住了直接修，修完继续，记录每一步的实际耗时
- 实时更新 `.kyb.md` 并 commit push
- 遇到各层问题分别记录到对应修复目标

**产出**：
- 可用的 `.kyb.md`（描述准确但可能冗长）
- 各层卡点清单（哪些修了、哪些发了 issue、哪些等解决）

### Round 2：优化到最优（onboarding agent）

**目标**：清理环境重跑，找到最优路径，记录冷/热启动耗时。

**原则**：
- 删除容器 → 重建 → 按 `.kyb.md` 重跑
- 优化流程：去冗余步骤、合并命令、加缓存利用
- 遇到应当上层处理的问题 → **给 kyb 发 issue**，在 `.kyb.md` 中记录"需要等 issue 修好才能优化"
- 记录最优耗时（冷启动、热启动分列）

**产出**：
- 精炼的 `.kyb.md`
- kyb 改进 issue 清单

### Round 3：intern 也能跑（verification agent，低 effort）

**目标**：用一个"不太聪明的 verification agent"验证文档是否足够清晰。

**方法**：
- 不加额外提示，只给 `.kyb.md`，让它在 DID 容器里执行
- 考虑调低模型 effort（如用 haiku / flash）
- 一般会因为 `.kyb.md` 缺少上下文卡住几次
- 每卡一次，修 `.kyb.md` 补上下文 → 重跑

**原则**：
- **不要给 verification agent 额外提示**——如果它卡了，就是文档的问题，不是它不够聪明
- 循环直到 intern 也能丝滑通过

**产出**：
- 经过"笨人测试"的 `.kyb.md`

### Round 4：最终检查（verification agent）

**目标**：确认一切丝滑。

**方法**：同 Round 3，但期望一次通过，零卡点。

**收敛标准**：verification agent 在 DID 容器内按 `.kyb.md` 执行，全流程通过率 100%。

## 与旧模型的映射

| 旧概念 | 新概念 |
|--------|--------|
| 四层（工具/依赖/数据/项目） | 八层（宿主机→kyb→镜像→运行时→外圈agent→DID→项目→.kyb.md） |
| 一个 agent | 双 agent（onboarding / verification） |
| verification agent 确认文档准确 | verification agent 确认文档足够简单到 intern 也能跑 |
| Round 2 形式化 | Round 2 优化到最优 |
| Round 4 他人验证 | Round 3 intern 验证 + Round 4 最终检查 |

## 修复策略矩阵

| 所属层 | 典型卡点 | 修复方式 | 谁修 |
|--------|---------|---------|------|
| 宿主机系统及网络 | 代理不通、SSH 未配、磁盘满 | 通知人类 | human |
| kyb 工具层 | CLI 缺能力、volume 权限不对 | 发 issue / 提 MR | human / onboarding agent |
| 外圈容器镜像层 | 缺 JDK、缺 Maven、缺 pip 包 | 改 Dockerfile → `kyb build` | onboarding agent |
| 外圈容器运行时层 | PG 不自启、环境变量不对 | 改 entrypoint.sh / config | onboarding agent |
| DID 容器层 | DID image 缺东西、DID 网络配置 | 改 DID 相关配置 | onboarding agent |
| 项目代码 | 配置写死 CI hostname、测试硬编码 | `git commit` 修项目 | onboarding agent |
| .kyb.md | 步骤遗漏、数字过时、歧义 | `git commit` 修文档 | onboarding agent |

## 已上船项目

已完成标准化 onboarding 的项目。

| 项目 | 状态 | 层模式 | R1 总耗时 | 热执行 | 探索耗时 | 关键卡点层 |
|------|------|--------|-----------|-------|---------|-----------|
| buyer-server | ✅ | 普通容器 | ~5min+? | ~1min | 未记录 | 工具层（Maven/Nexus） |
| nova | ✅ | 普通容器 | 未记录 | 未记录 | 未记录 | 工具层（复用） |
| data-ant | ✅ | 普通容器 | 未记录 | 未记录 | 未记录 | 依赖层（嵌套子模块）、项目层（集成测试） |
| triggers-refund | ✅ | DID 容器 | ~30min | ~2min | ~23min | 工具层（JDK 代理）、项目层（Kafka） |

## 项目 MR 流程

onboarding 过程中，onboarding agent 可能发现项目代码本身的问题（配置写死 CI hostname、测试硬编码、缺 .gitignore 条目等）、也需要向项目仓库提交 `.kyb.md`。这些变更走标准的 MR 流程。

### 分支策略

| 变更类型 | 分支名 | 说明 |
|---------|--------|------|
| 初始 `.kyb.md` | `kyb/onboarding` | 从 `master` 切出，包含完整 onboarding 文档 |
| `.kyb.md` 迭代更新 | 同上 | 在同一分支上持续 commit push |
| 项目代码修复 | `kyb/fix-<description>` | 从 `master` 切出，只修代码不混入 `.kyb.md` 变更 |
| kyb 工具改进 | 在 kyb 项目发 issue，不在此项目改 | |

### 工作流

#### 1. `.kyb.md` MR（标准情况）

```
kyb/onboarding 分支从头维护整个 onboarding 文档
  ↓
每轮迭代 commit push，MR 保持 open
  ↓
Round 4 通过后 → 合入 master
```

**注意**：MR 在 Round 1 就创建并保持 open，后续每轮迭代直接 push 到同一分支，MR 自动更新。

#### 2. 项目代码修复 MR

当发现项目代码本身有问题（如 `application-test.properties` 写死 CI hostname）：

```
从 master 切 kyb/fix-test-db-hostname
  ↓
修代码、commit、push
  ↓
glab mr create → 独立的 MR（与 .kyb.md MR 分开）
  ↓
在 .kyb.md 中记录"需合并此 MR 后流程才能简化"
```

#### 3. 两层 MR 的关系

```
.kyb.md MR（kyb/onboarding）
  └── 描述 onboarding 全流程、记录已知问题
      
项目代码修复 MR（kyb/fix-*）
  └── 修 CI 配置、测试硬编码等项目本身的问题
  └── 可选：不阻塞 onboarding，但优化后更顺畅
```

**原则**：
- 不要把项目代码修复混进 `.kyb.md` 分支——两者 MR 分开，各自 review
- `.kyb.md` 中的 "本项目卡点汇总" 应注明哪些问题已有独立 MR 在处理
- 项目代码修复 MR 可以合得比 `.kyb.md` MR 更快，也可以依赖它

#### 4. 实际案例：triggers-refund

| 变更 | 分支 | MR |
|------|------|-----|
| `.kyb.md` 完整文档 | `kyb/onboarding` | `base-service/triggers-refund!25` |
| `.gitignore` 加 `.env.kyb` | 混入 `kyb/onboarding` | 合在同一个 MR 中（小改动可接受） |
| Nexus 凭据预配 | kyb 项目 issue | `quick-n-dirty/kyb#3` |
| JDK 预装 | kyb 项目 issue | `quick-n-dirty/kyb#2` |
| Kafka service | kyb 项目 issue | `quick-n-dirty/kyb#4` |

## 附录：Round 时间记录模板

| 轮次 | 执行者 | 总耗时 | 各层卡点耗时 | 等待耗时 |
|------|--------|--------|------------|---------|
| R1 | onboarding agent | | 宿主机: / kyb: / 镜像: / 运行时: / DID: / 项目: | |
| R2 | onboarding agent | | 同上 | 冷: / 热: |
| R3 | verification agent | | —（只看文档层） | |
| R4 | verification agent | | — | |
