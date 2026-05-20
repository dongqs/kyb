# Onboarded Projects Reference

新项目 onboarding 时，先看此表找到技术栈最相似的项目，直接参考其 `.kyb.md` 和踩坑记录。

## 已上船项目总览

| 项目 | 负责人 | 外链 | 状态 | MR | 工具层 | 依赖层 | 数据层 | 项目层 | 子模块 | DID |
|------|--------|------|------|-----|--------|--------|--------|--------|--------|-----|
| [dredge-lxk](#dredge-lxk) | 建行 | [repo](https://git.leyantech.com/marketing/dredge-lxk) | ✅ 收敛 | open（待合） | Java 8 + Maven + Ruby | Nexus | PostgreSQL + ClickHouse | JUnit 圈人服务 | click/party/datasets（深嵌套） | ❌ |
| [buyer-center](#buyer-center) | 泽坤 | [repo](https://git.leyantech.com/base-service/buyer-center) | ✅ 收敛 | open（待合） | Java 21 + Maven | Nexus | PostgreSQL | JUnit 买家中心 | party | ❌ |
| [buyer-server](#buyer-server) | 泽坤 | [repo](https://git.leyantech.com/base-service/buyer-server) | ✅ 收敛 | — | Java + Maven | Nexus | PostgreSQL | — | — | ❌ |
| [nova](#nova) | 马林 | [repo](https://git.leyantech.com/base-service/nova) | ✅ 收敛 | — | Java + Maven | Nexus | — | — | — | ❌ |
| [data-ant](#data-ant) | 马林 | [repo](https://git.leyantech.com/base-service/data-ant) | ✅ 收敛 | — | Java + Maven | Nexus（嵌套子模块） | — | 集成测试 | 嵌套子模块 | ❌ |
| [triggers-refund](#triggers-refund) | 泽坤 | [repo](https://git.leyantech.com/base-service/triggers-refund) | ✅ 收敛 | — | Java + Maven + JDK 代理坑 | Nexus | — | Kafka | — | ✅ |

## 快速定位参考项目

### 按 JDK 版本

| JDK | 项目 | 备注 |
|-----|------|------|
| **8** | dredge-lxk | 需手动 `mise install java@corretto-8` |
| **21** | buyer-center, buyer-server, nova, data-ant, triggers-refund | kyb-base 预装 |

### 按数据库

| 数据库 | 项目 |
|--------|------|
| **仅 PostgreSQL** | buyer-center, buyer-server, nova, data-ant, triggers-refund |
| **PostgreSQL + ClickHouse** | dredge-lxk |

### 按外部服务

| 服务 | 项目 |
|------|------|
| **无额外服务（仅 PG）** | buyer-center, buyer-server |
| **ClickHouse** | dredge-lxk |
| **Redis** | dredge-lxk（嵌入式，不需要外部） |
| **Kafka** | triggers-refund |

### 按构建工具

| 工具 | 项目 |
|------|------|
| **Maven** | 全部 |
| **Ruby/bundler** | dredge-lxk |

### 按迁移工具

| 工具 | 项目 |
|------|------|
| **mig25** | 全部 |

## 各项目详情

### dredge-lxk

- **描述**: 京东人群定向（圈人）服务
- **MR**: https://git.leyantech.com/marketing/dredge-lxk/-/merge_requests/324（open，待合并）
- **关键踩坑**:
  - JDK 8 需手动 `mise install`
  - ClickHouse 24.2 容器必须（host CK 25.1 不兼容 JSON 类型）
  - 测试非幂等（`ON CONFLICT DO NOTHING`），重跑前 truncate
  - 子模块 `click` 嵌套 6+ 层
- **推荐参考场景**: Java 8 + ClickHouse 项目、子模块深嵌套项目

### buyer-center

- **描述**: 买家中心服务
- **MR**: https://git.leyantech.com/base-service/buyer-center/-/merge_requests/76（open，待合并）
- **关键踩坑**:
  - kyb-base 默认 JDK 8，需 `mise use -g java@corretto-21` 切换
  - `JAVA_HOME` 需显式 export（mvn 不自动读 mise）
  - HikariCP 连接池泄漏，PG max_connections 需扩到 200
  - 测试非幂等（模块间 test.sql 数据交叉污染）
- **推荐参考场景**: Java 21 + 仅 PG 项目、Maven multi-module 项目

### buyer-server

- **描述**: （历史项目）
- **关键踩坑**: Maven/Nexus 凭据
- **推荐参考场景**: 标准 Java Maven + PG 项目

### triggers-refund

- **描述**: （历史项目，DID 容器）
- **关键踩坑**: JDK 代理配置、Kafka 集成测试
- **推荐参考场景**: 需要 DID 容器、涉及消息队列的项目

## 常见坑速查

| # | 坑 | 首次出现 | 影响项目 | 一句话修复 |
|---|-----|---------|---------|-----------|
| 1 | mise 下载目录权限 | dredge-lxk | 所有 | `sudo chown -R dev:dev ~/.local/share/mise/downloads/` |
| 2 | JAVA_HOME 未设 | dredge-lxk | 所有 Java 项目 | `export JAVA_HOME=$(mise where java)` |
| 3 | mvn 找不到命令 | dredge-lxk | 所有 | `eval "$(mise activate bash)"` |
| 4 | .m2 所有权 | buyer-center | 有 shared volume 的项目 | `sudo chown -R dev:dev ~/.m2/` |
| 5 | CK 25.1 JSON 不兼容 | dredge-lxk | 用 CK 的项目 | 启动 CK 24.2 容器 |
| 6 | 测试非幂等 | dredge-lxk | ON CONFLICT 模式的项目 | truncate 重跑 |
| 7 | HikariCP 连接池泄漏 | buyer-center | Guice + Hikari 的项目 | 扩 PG max_connections |
| 8 | DID 容器空白 slate | dredge-lxk | DID 验证 | 需要 onboarding agent 预先装 JDK 和拷贝代码 |
