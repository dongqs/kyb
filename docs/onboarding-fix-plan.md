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

### 5. DID 容器不自启 PostgreSQL

**问题**: DID 容器不自启 PG，每个 DID onboarding 都要先手动 `pg_ctlcluster 16 main start`。

**影响项目**: 所有需要 PG 的 DID 项目

**已在**: 无

**修复方案**:
- DID entrypoint 加入 PG 自启逻辑
- 或 DID 镜像预装 PG 并配置自启

---

## P2 — 偶发但浪费

### 6. 容器内 /etc/hosts 无服务别名

**问题**: 项目 CI 中使用 `postgres` hostname 连接 PG，但在 kyb 容器内 `postgres` 不解析到 `127.0.0.1`。每个项目都要手动改或加 hosts。

**影响项目**: 全部 PG 项目

**已在**: issue #9

**修复方案**: entrypoint 自动添加常见服务别名到 `/etc/hosts`

### 7. proxy 配置兼容性

**问题**: `ALL_PROXY=socks5` 与 rustls/某些 HTTP 客户端不兼容，需手动切到 `https_proxy=http`。

**影响项目**: 需外网访问的工具

**已在**: 无

**修复方案**: entrypoint 同时设 `ALL_PROXY=socks5` 和 `https_proxy=http`，让各工具按需选择

---

## 实施顺序

```
P0-1  mise Java 默认版本     → entrypoint.sh    ~30min
P0-2  DID 工具链              → Dockerfile/did    ~2h
P1-3  mise config 持久化      → entrypoint.sh    ~1h
P1-4  共享 volume 权限         → kyb create       ~30min
P1-5  DID PG 自启             → entrypoint.sh    ~30min
P2-6  /etc/hosts 别名         → entrypoint.sh    ~15min
P2-7  proxy 兼容性            → entrypoint.sh    ~15min
```
