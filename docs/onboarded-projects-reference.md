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
| [form-manager](#form-manager) | 泽坤 | [repo](https://git.leyantech.com/base-service/form-manager) | ✅ 收敛 | open（待合） | Java 17 + Maven | Nexus | PostgreSQL | — | — | ❌ |
| [moneta](#moneta) | 泽坤 | [repo](https://git.leyantech.com/base-service/moneta) | ✅ 收敛 | open（待合） | Java 21 + Maven | Nexus（jOOQ） | PostgreSQL | — | — | ❌ |
| [rating-boost](#rating-boost) | 泽坤 | [repo](https://git.leyantech.com/base-service/rating-boost) | ✅ 收敛 | open（待合） | Java 21 + Maven | Nexus（jOOQ + Apollo + RocketMQ） | PostgreSQL | — | — | ❌ |
| [netflix](#netflix) | 方剑峰 | [repo](https://git.leyantech.com/marketing/netflix) | ✅ 收敛 | open（待合） | Java 8 + Maven | Nexus | — | — | — | ❌ |
| [recommendation-filter](#recommendation-filter) | 泽坤 | [repo](https://git.leyantech.com/recommendation/recommendation-filter) | ✅ 收敛 | open（待合） | Java 8 + Maven | Nexus | — | gRPC + Kafka | — | ❌ |
| [recommendation-finder](#recommendation-finder) | 郑一飞 | [repo](https://git.leyantech.com/recommendation/recommendation-finder) | ✅ 收敛 | open（待合） | Java + Maven | Nexus | — | — | — | ❌ |

> **负责人数据来源**: ntsb `resources/dbs.toml` 的 maintainer 字段 + 各项目 Git commit 贡献度交叉验证。添加新项目时同步更新。

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

### form-manager

- **描述**: hamilton-sdk 消费方，表单管理服务
- **MR**: !38（open，待合并）
- **关键踩坑**: Lombok 1.18.22 与 Java 21 不兼容（NoSuchFieldError），需切 Java 17
- **推荐参考场景**: Lombok + Java 17 项目

### moneta

- **描述**: hamilton-sdk 消费方，淘系买家标签服务，5 模块
- **MR**: !237（open，待合并）
- **关键踩坑**: jOOQ codegen class version 61.0 vs 52.0 冲突，DID 需手动装 Maven
- **推荐参考场景**: jOOQ codegen + multi-module 项目

### rating-boost

- **描述**: hamilton-sdk 消费方，5 模块，jOOQ codegen，Apollo + RocketMQ
- **MR**: !44（open，待合并）
- **关键踩坑**: mise 回退（JDK 21→17→8 切换），DID 需手动装 PG/pip/Maven，子模块 doudian-buyer
- **推荐参考场景**: jOOQ codegen + Apollo/RocketMQ 项目

### netflix

- **描述**: hamilton-sdk 消费方，4 模块，无 DB
- **MR**: !49（open，待合并）
- **关键踩坑**: JaCoCo 0.8.8 不兼容 JDK 21 class files，3 tests passed
- **推荐参考场景**: 无 DB + JaCoCo 项目

### recommendation-filter

- **描述**: hamilton-sdk 消费方，gRPC + Kafka，无 DB，12 tests
- **MR**: !205（open，待合并）
- **关键踩坑**: Java 21→8 切换（gRPC 不兼容 JDK 21），DID 验证通过
- **推荐参考场景**: gRPC + Kafka 项目

### recommendation-finder 🏆

- **描述**: hamilton-sdk 消费方，无 DB，纯 Mock 测试，23 tests
- **MR**: !172（open，待合并）
- **关键踩坑**: 无卡点 — 全 4 轮收敛，首位完成
- **推荐参考场景**: 纯 Mock 测试、极简项目

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
| 9 | Lombok + Java 21 不兼容 | form-manager | 用 Lombok 的项目 | 切 Java 17 编译或升级 Lombok |
| 10 | JaCoCo 0.8.8 + JDK 21 | netflix | 用 JaCoCo + JDK 21 的项目 | 升级 JaCoCo 或加 `-Djacoco.skip=true` |
| 11 | jOOQ codegen class version 冲突 | moneta/rating-boost | 用 jOOQ + JDK 21 的项目 | 确保 Maven 运行在兼容的 JDK 版本 |
