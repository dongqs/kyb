# Onboarding 专项修复

从 14 个已上车项目的 `.kyb.md` 踩坑记录和实际操作中提取的 kyb 自身问题。修完这些，后续项目 onboarding 可减少 5-10min 重复劳动。

## P0 — 每项目必踩

### 1. mise 默认 Java 版本

**问题**: kyb-base entrypoint 激活 `corretto-8` 作为全局默认，但 12/14 Java 项目都需要 JDK 21（或 17）。每个 onboarding 第一步就是 `mise use -g java@corretto-21` + `export JAVA_HOME`。

**影响项目**: 全部 Java 项目（buyer-center, moneta, rating-boost, form-manager, netflix, recommendation-filter, data-ant, nova, buyer-server, triggers-refund, peroration, dredge-lxk）

**已在**: issue #2（预装 JDK 21，但未改默认版本）

**修复方案**:
- entrypoint 将 mise 全局默认从 `corretto-8` 改为 `corretto-21`
- 需 JDK 8 的项目（dredge-lxk, netflix, recommendation-filter, recommendation-finder, peroration）自行 `mise use -g java@corretto-8` 切换
- 改 `entrypoint.sh` 中 mise activation 逻辑

**踩坑引用**: 12 个项目的踩坑 #1 都是 Java 版本问题

**状态**: ⚠️ 已实现待验证 — 实际修正比描述更彻底（审计发现镜像里根本没有 JDK，已直接添加 corretto-21 到 mise 工具链 + Dockerfile 安装层）。详见 MR !52，需 `kyb build` 重建镜像后验证。

### 2. DID 容器工具链空白

**问题**: DID 容器只包含 Alpine 基础系统，没有 JDK/Maven/pip3/mig25/gh/Claude Code。每个 DID onboarding 都要手动装一遍，且 shared volume 权限要额外修。

**影响项目**: triggers-refund, form-manager, moneta, rating-boost, netflix, recommendation-filter, recommendation-finder + 未来所有 DID 项目

**已在**: issue #11

**修复方案**:
- 方案 A: DID 镜像复用外圈 kyb-base 的 toolchain（`--volumes-from` 或 bind mount `/home/dev/.local`）
- 方案 B: 单独构建 `kyb-did-base` 镜像，预装 JDK/Maven/pip3/mig25
- 同时解决 shared volume UID 问题（issue #8）

**踩坑引用**:
- `sudo chown -R dev:dev ~/.m2 ~/.local/share/mise/downloads`（common pitfall #1/#4）
- DID 容器 JDK/Maven 缺失（common pitfall #8）

**状态**: 🔄 审计发现描述已过时 — DID 容器实际使用同一 `kyb-base` 镜像（Ubuntu 24.04，非 Alpine），toolchain 共享，只是 PG 不自启+无 pip/mig25。PG 问题已随 MR !52 修复（去掉了 `KYB_DID` guard），pip/mig25 在 DID 容器中仍有可能未就绪（entrypoint 第 206 行的 pip install 受 `set -e` 影响可能跳过），需进一步确认。

---

## P1 — 高频痛

### 3. `mise use -g` 不持久

**问题**: entrypoint 在容器启动时会覆盖 mise 全局配置，导致 `mise use -g java@corretto-21` 不生效。项目不得不使用绝对路径设 `JAVA_HOME`，增加了 onboarding 复杂度。

**影响项目**: recommendation-filter（踩最深）、moneta（R4 发现 JDK 版本回退）、rating-boost

**已在**: 无

**修复方案**:
- entrypoint 在激活 mise 前先检查用户是否已有自定义 config
- 或提供一个 `~/.kyb-override.env` 机制，让用户配置持久化覆盖
- 或在 `CLAUDE.md` 中给出 fix 而非让每个项目在 `.kyb.md` 里绕

**踩坑引用**: recommendation-filter 踩坑 #2（`mise use -g` 不持久）

### 4. 共享 volume 权限

**问题**: 容器多次重建后 `~/.m2/repository` 和 `~/.local/share/mise/downloads` 的 owner 变成 root，导致 Maven/mise 写失败。每个 onboarding 都要 `sudo chown`。

**影响项目**: 全部 Java 项目

**已在**: common pitfall #1/#4

**修复方案**:
- `kyb create` 入口自动执行 `sudo chown -R dev:dev ~/.m2 ~/.local/share/mise/downloads`
- 或 entrypoint 启动时检测 owner 并修复

**状态**: ✅ 已实现待验证 — entrypoint.sh 已补上 `~/.local/share/mise/downloads`（原只修了 `.gradle` + `.m2/repository`）。详见 MR !52。

### 5. DID 容器不自启 PostgreSQL

**问题**: DID 容器不自启 PG，每个 DID onboarding 都要先手动 `pg_ctlcluster 16 main start`。

**影响项目**: 所有需要 PG 的 DID 项目

**已在**: 无

**修复方案**:
- DID entrypoint 加入 PG 自启逻辑
- 或 DID 镜像预装 PG 并配置自启

**状态**: ✅ 已实现待验证 — entrypoint.sh 已移除 `KYB_DID` 限制，PG 在所有容器（含 DID）中自动启动。详见 MR !52。

---

## P2 — 偶发但浪费

### 6. 容器内 /etc/hosts 无服务别名

**问题**: 项目 CI 中使用 `postgres` hostname 连接 PG，但在 kyb 容器内 `postgres` 不解析到 `127.0.0.1`。每个项目都要手动改或加 hosts。

**影响项目**: 全部 PG 项目

**已在**: issue #9

**修复方案**: entrypoint 自动添加常见服务别名到 `/etc/hosts`

**状态**: ✅ 已实现待验证 — entrypoint.sh 已将 `postgres clickhouse kafka redis` 写入 `/etc/hosts`。详见 MR !52。

### 7. proxy 配置兼容性

**问题**: `ALL_PROXY=socks5` 与 rustls/某些 HTTP 客户端不兼容，需手动切到 `https_proxy=http`。

**影响项目**: 需外网访问的工具

**已在**: 无

**修复方案**: entrypoint 同时设 `ALL_PROXY=socks5` 和 `https_proxy=http`，让各工具按需选择

---

## 实施顺序

```
P0-1  mise Java 默认版本     → mise.config.toml + Dockerfile   ✅ 已实现（MR !52）
P0-2  DID 工具链              → Dockerfile/did    ~2h
P1-3  mise config 持久化      → entrypoint.sh    ~1h
P1-4  共享 volume 权限         → entrypoint.sh    ✅ 已实现（MR !52）
P1-5  DID PG 自启             → entrypoint.sh    ✅ 已实现（MR !52）
P2-6  /etc/hosts 别名         → entrypoint.sh    ✅ 已实现（MR !52）
P2-7  proxy 兼容性            → entrypoint.sh    ~15min
```

---

## 批量上船后的补充项

扫描 70 个候选项目后发现的新问题，基于原列表补充或提级：

### ⬆️ 升级: /etc/hosts 服务别名（P2 → P1）

**原因**: oversea 组有 ~25 个服务，其中 15+ 用 PG，每个都要手动解析 `postgres` hostname。原估影响"全部 PG 项目"约 10 个，实际扩展后是 ~40+ 个项目。

**修复不变**: entrypoint 自动加 `127.0.0.1 postgres clickhouse kafka redis` 等常见别名。

### ➕ 新增 P1: 非 Maven 构建检测

**问题**: 当前 `.kyb.md` 模版和 onboarding 流程假设项目使用 Maven（`pom.xml`）。扫描发现：

| 项目 | 构建方式 | 技术栈 |
|------|---------|--------|
| store-home | build.sh | Java + PG（非 Maven） |
| assistant | build.sh | Java |
| business-rule | Python + Airflow | Python |
| citi | Python | Python ML |
| digismart/RPA 系列 | — | 脚本类 |

批量上船时无法假设 `pom.xml` 存在。模板和 `complete流程` 需检测构建文件类型并选择对应命令。

**修复方案**:
- `complete流程` 步骤 5（编译）改为自适应：`pom.xml` → `mvn` / `build.gradle` → `gradle` / `build.sh` → `./build.sh` / `pyproject.toml` → `uv sync`
- `.kyb.md` 模版增加构建类型声明字段

### ➕ 新增 P2: CI 变量自动提取

**问题**: 每个项目的 `.gitlab-ci.yml` 中 `POSTGRES_DB`、服务别名、JDK 版本等信息目前需人工读取填入 `CI 配置参考` 表。70 个项目重复劳动。

**修复方案**: 写一个 `kyb onboard scan` 子命令，自动从 `.gitlab-ci.yml` 提取：
- `services[].name` → 外部服务依赖表
- `variables.POSTGRES_DB` → DB 名
- `image` → 构建镜像
- 输出 markdown 表格直接粘贴到 `.kyb.md`

### 更新后的总优先级

```
P0-1  DID 工具链               → Dockerfile/did    ~2h      ← 影响 70 个项目的 DID 验证
P0-2  mise config 持久化       → entrypoint.sh    ~1h      ← 不修则排查成本翻倍
P1-1  /etc/hosts 服务别名       → entrypoint.sh    ✅ 已实现（MR !52）⬆️ 从 P2 升级
P1-2  共享 volume 权限          → entrypoint.sh    ✅ 已实现（MR !52）
P1-3  非 Maven 构建检测         → 模版 + flow      ~1h      ← ➕ 新增
P1-4  DID PG 自启              → entrypoint.sh    ✅ 已实现（MR !52）
P2-1  mise Java 默认版本       → 镜像层           ✅ 已实现（MR !52）— 直接装 JDK 21
P2-2  CI 变量自动提取           → kyb onboard scan ~2h      ← ➕ 新增
P2-3  proxy 兼容性             → entrypoint.sh    ~15min
```

---

## 模版提升计划 — 事前事后检查

### 问题

当前 `.kyb.md` 模版遵循 Unix 哲学："静默假设一切正常，报错了再说"。这对**已配好的环境**没问题，但 onboarding 是在**配环境**——每一步的前提条件都可能不满足。

典型失败模式：

```bash
# 当前做法：假设成功
mvn test
# → 如果 JDK 版本不对，报 confusing 的 class version error
# → 如果 PG 没启，报 connection refused
# → 如果 ~/.m2 权限不对，报 permission denied
```

agent 花大量时间反向排查——从"编译失败"追溯"JDK 版本不对"再追溯"mise 配置被重置"。每层查完才能修。

### 原则

**主动检查好于被动报错。** 每步分三段：

```
事前检查 → 执行 → 事后验证
         ↓
   条件不满足则修复或中止
```

### 模版改动

#### 事前检查（每步开头加 `assert` 块）

```bash
# 示例：工具确认步骤
# assert: java 版本正确
java -version 2>&1 | grep -q "openjdk version \"21" \
  || { echo "❌ JDK 不是 21，当前: $(java -version 2>&1)"; mise use -g java@corretto-21; }
# assert: JAVA_HOME 已设
test -n "$JAVA_HOME" || export JAVA_HOME=$(mise where java)
# assert: PG 可连
pg_isready -q || pg_ctlcluster 16 main start

# → 然后才执行正式命令
mvn test
```

#### 事后验证（每步末尾加 `verify` 块）

```bash
# 示例：数据库步骤
MIG25_DSN="..." mig25 upgrade

# verify:  migration 全部到位
mig25 list | tail -5
# verify:  关键表存在
psql -U postgres -d mydb -c "\dt core.*" | grep -q "buyer_sessions" \
  && echo "✅ core.buyer_sessions 存在" \
  || echo "❌ 缺少 core.buyer_sessions"
```

#### 完整流程模板对照

| 当前步骤 | 事前检查 | 执行 | 事后验证 |
|---------|---------|------|---------|
| 1. 工具确认 | java/mvn/pg 版本断言 | —（纯检查步骤本身） | 全部 ✅ |
| 2. 子模块 | git 可用性 | `git submodule update` | 子模块目录非空 |
| 3. 数据库 | PG 运行、DB 不存在 | `createdb` + `mig25 upgrade` | `mig25 list` 总量、关键表 |
| 4. 代码生成 | DSN 可达 | `mig25-codegen generate` | 生成目录非空 |
| 5. 编译 | JAVA_HOME、凭据 | `mvn compile` | BUILD SUCCESS |
| 6. 测试 | 外部服务探测 | `mvn test` | 测试数 ≥ 预期、0 failures |

### 预期效果

- **排查时间减半**: 事前检查把失败提前到具体断言行，而不是等深层命令报 confusing 错误
- **自修复**: 常见条件不满足（PG 没启、JDK 版本不对）可直接自动修复而非中止
- **agent 友好**: agent 看到清晰断言失败比解析 Maven stack trace 快得多
- **人类也可读**: 写死 `java -version | grep 21` 比隐含假设更明确

### 实施顺序

1. 改 `docs/onboarding.kyb.md` 模版 — 加入 assert/verify 模式（~1h）
2. 已有 `.kyb.md` 逐步迁移 — 先改高频使用的（buyer-center, moneta, netflix）
3. 新建 `lib/kyb/assert.rb` — 封装通用断言函数（`Kyb.assert_java`, `Kyb.assert_pg` 等）
