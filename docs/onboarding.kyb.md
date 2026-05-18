# .kyb.md — kyb 项目 onboarding 标准作业程序

---

> **如何使用本文档**：
> - **新项目 onboarding** → `cp docs/onboarding.kyb.md ~/projects/<项目>/.kyb.md` → `git commit -m "chore: add .kyb.md"` → `git push` → `glab mr create`。复制整个文件，不要手工摘录，防止错漏。MR 创建后保持 open，后续迭代直接 push 更新。
> - **回顾方法论** → 阅读最下方"方法论文档"章节（分层模型/双 agent/四轮迭代/写作原则/MR流程）
>
> 文件结构：上方为可直接使用的 `.kyb.md` 模版，下方为 kyb 方法论文档。

---

# .kyb.md — <Project>

<一句话：项目用途、技术栈、关键依赖>

## 设计原理

本文档按**系统论**（分层抽象）和**控制论**（闭环反馈）两个原理组织。

**分层**（每步标注所属层）：
`[工具层]` 运行时/JDK/Gradle/缓存 → `[依赖层]` Nexus/子模块/PyPI → `[数据层]` DB/migration/codegen → `[项目层]` 构建/测试
→ 每步失败时先查对应层的踩坑记录

**闭环**（每步格式 = 执行→观察→判断→调整）：
```
执行命令 → 检查预期输出 → ✅ 继续 / ❌ 查本层排查指引 → 修复后重试
```

**通知人类**：遇到 agent 无法处理的层（宿主机/网络/权限），用 `kyb notify urgent/blocked/done` 找人。
**收敛标准**：连续两轮零新卡点、零歧义、verification agent 一次通过时收敛。新增依赖则启动新一轮。

> **Onboarding agent**（有 docker sock，全栈可修）：按完整流程逐步骤执行。遇到卡点判断所属层→修对应层→更新本文档→继续。
> **Verification agent**（无 docker sock，只读验证）：按完整流程逐步骤执行。卡住了说明本文档有误，反馈给 onboarding agent 修。
> **人类**：直接看 Quick Start。
> **新依赖**：按流程再跑一轮，新增的卡点和缓存信息记入对应章节。

## 预装状态

kyb-base 已预装：PostgreSQL 16 ✅ | Python 3.10 ✅ | mise ✅
需手动装：<JDK/Maven/其他>（`mise install <tool>` + `mise use -g`，~Nmin）

⚠️ `mise install` 后必须 `mise use -g` 激活，否则命令找不到。

> **旧项目 Lombok 兼容性**：若项目使用的 Lombok 版本较旧（parent POM 为 2022 年前），
> JDK 17+ 编译时可能报 `IllegalAccessError: cannot access com.sun.tools.javac...`。
> 此情形需改用 JDK 11（`mise install java@corretto-11 && mise use -g java@corretto-11`）。
> 不要试图加 `--add-exports`——旧 Lombok 访问的内部 API 太多，逐个添加不现实。

> **非交互式 shell 的 mise 激活**：`docker exec su - dev -c "eval \"\$(mise activate bash)\" && java -version"`
> 在非交互式 shell 中无效——mise 的 hook 函数无法注入。
> 如有此场景需手动设环境变量：
> ```bash
> JAVA_HOME=$HOME/.local/share/mise/installs/java/corretto-<version>
> export PATH=$JAVA_HOME/bin:$PATH
> ```
> 交互式 Claude Code 会话不需要此操作。

## 外部服务依赖

| 服务 | CI 有? | 本地有? | 说明 |
|------|--------|--------|------|
| PostgreSQL | <✅/❌> | ✅（kyb-base） | DID 需手动 `pg_ctlcluster` 启动 |
| <Kafka等> | | | |

Agent 启动前先探测可用服务，根据结果决定完整流程或降级方案。

## Quick Start

```bash
# 以下命令以 root 执行。pip3 等需 su - dev。mise 管理的工具（java 等）需 bash -l -c 或 eval "$(mise activate bash)"。
# 0. 前提 — 容器已创建，PG 已启动
pg_isready                                           # → accepting connections

# 1. 工具
<安装JDK等> && mise use -g <tool>
eval "$(mise activate bash)" && java -version   # 验证 JDK 已激活
su - dev -c "pip3 install <工具>"

# 2. 子模块
cd ~/projects/<project> && git submodule update --init --recursive

# 3. 数据库
psql -U postgres -c "CREATE DATABASE <db>"
MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25 upgrade

# 4. 代码生成
MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25-codegen generate

# 5. 编译 + 测试
export <凭据等> && <构建命令>
```

## 启动前检查

```bash
# [工具层] PG 可能未启动（DID 容器不自启）
pg_isready                                           # → accepting connections（否则 pg_ctlcluster 16 main start）
```

## Verification agent 指引

**你正在以 verification agent 身份执行**。你没有 docker sock，不能修任何东西。你的唯一任务是按 `完整流程` 逐步骤执行，每步验证预期输出。

**反馈方式**：每步执行结果写入 `/tmp/.kyb-verification.md`，onboarding agent 在外圈用 `docker exec` 实时查看（`/tmp` 随容器销毁自动清理，不需要操心旧日志）。

```bash
# 每步格式：追加到 /tmp/.kyb-verification.md
echo "- Step N: Command... ✅" >> /tmp/.kyb-verification.md
# 卡住时：
echo "- Step N: ❌ 现象 | 原因" >> /tmp/.kyb-verification.md
# 全部完成：
echo "" >> /tmp/.kyb-verification.md && echo "## 结果" >> /tmp/.kyb-verification.md && echo "- ✅ 全流程通过 / ❌ 卡在第N步" >> /tmp/.kyb-verification.md
```

- ✅ 通过 → 写日志，继续下一步
- ❌ 卡住 → 写日志记录现象和原因。退出后 onboarding agent 会读到。

**不要尝试修任何问题**。没有 docker sock，你修不了。卡住就是文档的问题，交给外圈修。

> **DID 容器内 `docker exec` 注意事项**（供 onboarding agent 参考）：
> `docker exec` 默认以 root 身份执行，其创建的文件（如 Maven 缓存 `~/.m2/repository`）
> 会被 root 拥有。后续 `su - dev -c "mvn ..."` 会因权限不足失败。
> 如需在 DID 容器内执行 Maven 命令，始终用 `su - dev -c "..."` 而非裸 `docker exec`。
> 若已污染，执行 `docker exec ... chown -R dev:dev ~/.m2` 修复。

## 完整流程

> 每步格式：**执行** → **观察**（检查预期输出）→ **判断**（✅ 继续 / ❌ 查对应层排查指引）

### 1. 工具确认 [`工具层`]

```bash
pg_isready                                     # → accepting connections  ✅ | ❌ 启PG
bash -l -c "java -version"                    # → openjdk 21.0.x  ✅ | ❌ mise install + use -g
<构建工具> --version | head -1                  # → ver  ✅ | ❌ 见排查
```

**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| `java: not found` | 未安装/未激活 | `mise install <tool>` + `mise use -g` |
| 构建工具找不到 | 未安装 | `mise install <tool>` |
| PG 连不上 | 服务未启 | `pg_ctlcluster 16 main start` |
| pip3 找不到 | 用户不对 | `su - dev -c "pip3 ..."` 或 `pip3 install --user` |
| 代理问题 | socks5 与 rustls 不兼容 | 用 `https_proxy=http` 而非 `ALL_PROXY=socks5` |
| Gradle 找不到指定版本 JDK | 未配 toolchain 路径 | `printf 'org.gradle.java.installations.paths=<JDK路径>' >> ~/.gradle/gradle.properties` |
| DID 容器内 `.gradle`/`.m2` 写拒绝 | share volume 属主(501) ≠ 容器 UID(1000) | docker exec 先 `sudo chown -R dev:dev /home/dev/.gradle` |
| Lombok `IllegalAccessError`（`cannot access com.sun.tools.javac...`） | JDK 17 强封装 + 旧 Lombok | 改用 JDK 11（`mise install java@corretto-11 && mise use -g java@corretto-11`） |

### 2. 子模块 [`依赖层`]

```bash
cd ~/projects/<project> && git submodule update --init --recursive
# → 子模块目录非空  ✅ | ❌ 查嵌套 submodule
```

**❌ 排查**：嵌套 submodule → 加 `--recursive`。网络问题 → 确认 `NO_PROXY` 含内网域名。

### 3. 数据库 [`数据层`]

```bash
psql -U postgres -c "CREATE DATABASE <db>;"
# → CREATE DATABASE  ✅ | ❌ 确认 PG 运行

MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25 upgrade
# → migrations 全部执行完毕  ✅ | ❌ 见排查
# 执行后用 mig25 list 确认总量
```

**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| DB 名不匹配 | 与 CI/代码不一致 | 查 CI `POSTGRES_DB` |
| mig25 找不到迁移 | 目录配置 | 确认 `m25.yml` 中 `dir` |
| `mig25: command not found` | 未安装 | `pip3 install mig25 mig25-codegen` |

### 4. 代码生成 [`数据层`]

```bash
MIG25_DSN="postgresql://postgres:postgres@127.0.0.1:5432/<db>" mig25-codegen generate
# → 生成完成  ✅ | ❌ 见排查
```

**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| schema 不存在 | migration 未执行 | 回到步骤 3 重跑 |
| 连接 DB 失败 | DSN 不对 | 确认指向 `localhost:5432` |

### 5. 编译 [`工具层`]

```bash
export <凭据> && <构建命令> compileKotlin
# → BUILD SUCCESS  ✅ | ❌ 见排查
```

> 如果项目在 CI 中设置了 `GRADLE_USER_HOME`（如 `GRADLE_USER_HOME=.cache`），本地编译时也需要同步设置以复用缓存。

**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| `Could not resolve` 依赖 | 仓库凭据 | 设对应环境变量 |
| JDK 找不到 | 未激活 | `eval "$(mise activate bash)" && java -version` |
| 构建工具下载慢 | 网络 | 首次冷启动需等待，热启动秒级 |
| 编译错误（非依赖） | 项目层 | 检查具体报错 |

### 6. 测试 [`项目层`]

先探测外部服务：
```bash
curl -s <service>:<port> >/dev/null 2>&1 && echo "有 <服务>" || echo "无 <服务>，降级"
```

```bash
export <凭据> && <构建命令> test
# → BUILD SUCCESS  ✅ | ❌ 见排查
```

**❌ 排查**：
| 现象 | 可能原因 | 修复 |
|------|---------|------|
| 全部失败/无法启动 | DB 连不上 | 确认 DB 用 `localhost` 而非 CI hostname |
| 某集成测试失败 | 缺外部服务 | 启动对应服务或用 mock/in-memory |
| 单测级别失败 | 项目层 | 检查具体报错 |

---

## CI 配置参考

以下从 `.gitlab-ci.yml` 提取，是项目依赖的权威来源。本地运行时对照参考。

| 来源 | 内容 |
|------|------|
| **构建镜像** | <CI镜像>（内含工具清单） |
| **外部服务** | <服务名及其别名> |
| **DB 名** | <`POSTGRES_DB` 值> |
| **仓库凭据** | <用户名> |
| **迁移工具** | <安装命令> |
| **缓存路径** | <CI中的路径> |

## 冷启动 / 缓存初始化

| 资源 | 缓存方式 | 所属层 | 自动? | 冷启动方式 | 等待耗时（冷→热） |
|------|---------|--------|-------|-----------|-------------------|
| <JDK/工具> | `kyb-mise-cache` | 工具层 | ❌ | `mise install <tool>`（注意代理） | Nmin→0s |
| 构建依赖 | shared volume | 工具层 | <✅/❌> | 首次构建自动下载 | Nmin→Ns |
| Git 子模块 | 项目目录 | 依赖层 | ❌ | `git submodule update --init --recursive` | Ns→0s |
| DB + migration | 容器内 pg data | 数据层 | ❌ | `createdb` + `mig25 upgrade` | Ns→Ns |
| Codegen | `build/generated/` | 数据层 | ❌ | `<codegen命令>` | Ns→Ns |
| 测试 | — | 项目层 | ❌ | `test` 命令 | Ns→Ns |

## 踩坑记录

| # | 问题 | 所属层 | 现象 | 原因 | 修复 |
|---|------|--------|------|------|------|
| 1 | JDK 17 + 旧 Lombok 不兼容 | 工具层 | `Fatal error compiling: IllegalAccessError: cannot access com.sun.tools.javac...` | 旧 Lombok 访问 JDK 内部 API，JDK 17 强封装 | 改用 JDK 11 |
| 2 | DID 容器 Maven 缓存 root 权限 | 工具层 | `rm: cannot remove: Permission denied` / Maven install 失败 | `docker exec` 以 root 运行，Maven 缓存文件被 root 创建 | 始终用 `su - dev -c "..."` 而非裸 `docker exec` |

## 按层快速排查

| 所属层 | 常见失败 | 排查入口 |
|--------|---------|---------|
| **工具层** | JDK 未激活、仓库凭据、PG 未启动、工具找不到 | 步骤 1 排查表 |
| **依赖层** | 子模块为空、嵌套 submodule | 步骤 2 排查表 |
| **数据层** | migration 找不到、codegen 报错 | 步骤 3-4 排查表 |
| **项目层** | 测试失败（缺外部服务、代码错误） | 步骤 6 排查表 |

## Round 1 踩坑探索耗时

| 卡点 | 所属层 | 探索耗时 | 排查过程 |
|------|--------|---------|---------|
| （每遇一个填一行） | | | |
| **合计** | | | |

### 各轮总耗时

| 轮次 | 总耗时 | 踩坑探索 | 执行等待 |
|------|--------|---------|---------|
| Round 1 | | | |
| Round 2 | | | |
| Round 3 | | | |
| Round 4 | | | |

## 本项目卡点汇总

- **kyb 工具待改进**：需要改 kyb 本身才能解决的
- **环境依赖**：需要宿主机配合的
- **项目自身**：项目代码/配置问题

## 迭代记录

| 轮次 | 耗时 | 变化 |
|------|------|------|
| Round 1 | | |
| Round 2 | | |
| Round 3 | | |
| Round 4 | | |

---

# 方法论文档

以下为 kyb onboarding 的方法论和参考信息。非模版内容，不须填入项目。

## 完整分层模型

从宿主机到 `.kyb.md`，共 8 层。每层定义"该层有什么"和"该层卡了谁修"。

```
宿主机系统及网络 ← macOS/Orbstack/代理/DNS/SSH/磁盘 → 通知人类
  ↓
kyb 工具层       ← CLI/Docker编排/配置管理/volume    → 发issue/提MR
  ↓
外圈容器:
  ├─ 镜像层     ← Dockerfile/mise预装/OS包          → 修Dockerfile→kyb build
  ├─ 运行时层   ← entrypoint/mount/服务启停/环境变量  → 修entrypoint/config
  └─ onboarding agent ← 有docker sock, 全栈可修
  ↓
DID容器(内圈):
  ├─ DID镜像层
  ├─ DID运行时层
  └─ verification agent ← 无docker sock, 只读验证
  ↓
项目代码       ← 源码/构建/测试/配置               → git commit修项目
  ↓
.kyb.md       ← 文档本身                          → git commit修文档
```

**核心规则**：该修 kyb 的不要塞进 `.kyb.md` 当踩坑记录。该修项目的不要用 onboarding 流程绕过去。卡点诊断从下往上查，找到真正所属层再修。

## 双 agent 模型

| 维度 | onboarding agent | verification agent |
|------|-----------------|-------------------|
| 所在位置 | 外圈 kyb 容器 | 内圈 DID 容器 |
| docker sock | 有 | 无 |
| 能力 | 全栈诊断 + 修各层 | 只读 `.kyb.md` 验证 |
| 执行轮次 | Round 1-2 | Round 3-4 |
| 卡住了说明 | 该修某层 | `.kyb.md` 有误 |

### 通知人类

| 场景 | 命令 |
|------|------|
| 全流程跑通（长任务完成） | `kyb notify done "项目名 onboarding 完成"` |
| 需要人工介入 | `kyb notify urgent "需要处理：..."` |
| 需要确认 | `kyb notify blocked "需要确认：..."` |

## 四轮迭代

```
Round 1 ─→ 跑通不优化 ─→ 实时更新.kyb.md并push
  │
  v
Round 2 ─→ 优化到最优 ─→ 清理重跑、记耗时、发kyb issue
  │
  v
Round 3 ─→ intern也能跑 ─→ 低effort agent + 修文档上下文
  │
  v
Round 4 ─→ 最终检查 ─→ 丝滑通过 = 收敛
```

### Round 1：先跑通
**执行者**：onboarding agent | **目标**：从零到测试全流程跑通一次
- 复制模版：`cp docs/onboarding.kyb.md ~/projects/<项目>/.kyb.md` → `git commit -m "chore: add .kyb.md"` → `git push` → `glab mr create`。MR 保持 open。
- 不要优化。卡住了直接修，修完继续，记下每一步实际耗时
- 遇到各层问题分别记入对应修复目标（kyb issue/修项目/修文档）
- 实时更新 `.kyb.md` 并 commit push
- 记录每个卡点的探索过程（现象→原因→修复→所属层→耗时）
- 创建 `.kyb.md` MR（`kyb/onboarding` 分支，Round 1 创建并保持 open）

### Round 2：优化到最优
**执行者**：onboarding agent | **目标**：找到最优路径，记录冷/热启动耗时
- 删除容器 → 重建 → 按 `.kyb.md` 重跑
- 去冗余步骤、合并命令、加缓存利用
- 遇到应当上层处理的问题 → 发 kyb issue，在 `.kyb.md` 中记录"需要等 issue 修好才能优化"
- 记录冷启动/热启动分别的耗时

### Round 3：intern 也能跑
**执行者**：verification agent（低 effort） | **目标**：文档足够清晰

**onboarding agent 操作**：创建 DID 容器（全新 `git clone`，无污染）→ 让 verification agent 进入 → 指示它读 `.kyb.md` 的 `Verification agent 指引` → 按 `完整流程` 执行。同时在外部用 `docker exec did-<project> tail -f /tmp/.kyb-verification.md` 实时监控进度。等到文件出现 `## 结果` 判定完成。

**verification agent 操作**：不加额外提示，只按 `.kyb.md` 的 `完整流程` 逐步骤执行。
- 考虑调低模型 effort（如 haiku / flash）
- 不要给 agent 额外提示——卡了就是文档的问题，不是它不够聪明
- 循环直到 intern 也能丝滑通过

### Round 4：最终检查
**执行者**：verification agent | **目标**：一次通过，零卡点
- 收敛标准：verification agent 在 DID 容器内按 `.kyb.md` 执行全流程一次通过

## 写作原则

1. **每条命令可独立复制粘贴执行**，不含歧义
2. **失败路径也写**："如果 X 报错，执行 Y"
3. **冷/热路径分开**，明确判断条件
4. **每个步骤含预期输出**，方便 agent 校验
5. **每步格式 = 执行→观察→判断→调整**，形成闭环
6. **先看 CI，不要猜**：`.gitlab-ci.yml` 是依赖的权威来源。扫 services/variables/before_script/image 再动手
7. **声明外部服务依赖**：列出 Kafka / Redis 等，注明 CI 有/无、本地有/无
8. **`mise install` 后必须 `mise use -g` 激活**
9. **分层记录卡点**：每步失败时判断所属层，下层问题抽象复用，上层记入项目专属节
10. **闭环记录**：每个坑包含"现象→原因→修复"完整链条
11. **路径用绝对路径或用 `~` 起始**，避免 `cd` 隐含状态
12. **文档本身也可迭代**：新问题出现时再跑一轮更新

## MR 流程

| 变更类型 | 分支名 | 说明 |
|---------|--------|------|
| `.kyb.md` 初始 + 迭代 | `kyb/onboarding` | Round 1 创建 MR 并保持 open，后续 push 自动更新 |
| 项目代码修复 | `kyb/fix-<description>` | 从 `master` 切，独立 MR，不混入 `.kyb.md` 变更 |
| kyb 工具改进 | — | 在 kyb 项目发 issue，不在此项目改 |

- `.kyb.md` MR 在 Round 1 就创建，后续迭代同一分支 push，MR 自动更新
- 不要把项目代码修复混进 `.kyb.md` 分支——两者分开 review
- `.kyb.md` 中"kyb 工具待改进"清单注明已发 issue 的链接

## 已上船项目

| 项目 | 状态 | 层模式 | R1 总耗时 | 热执行 | 探索耗时 | 关键卡点层 |
|------|------|--------|-----------|-------|---------|-----------|
| buyer-server | ✅ 收敛 | 普通容器 | ~5min+? | ~1min | 未记录 | 工具层（Maven/Nexus） |
| nova | ✅ 收敛 | 普通容器 | 未记录 | 未记录 | 未记录 | 工具层（复用） |
| data-ant | ✅ 收敛 | 普通容器 | 未记录 | 未记录 | 未记录 | 依赖层（嵌套子模块）、项目层（集成测试） |
| triggers-refund | ✅ 收敛 | DID 容器 | ~30min | ~2min | ~23min | 工具层（JDK 代理）、项目层（Kafka） |
| hamilton | ✅ 收敛 | 普通容器 | ~16min | ~17s | 2min | 工具层（mise 激活、Gradle 冷启动） |
| hamilton-sdk | ✅ 收敛 | 普通容器 | ~4min | ~32s | ~2min | 工具层（GraalVM socks5 代理、DID 权限） |
