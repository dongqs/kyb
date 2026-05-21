# Onboarded Projects Reference

新项目 onboarding 时，先看此表找到技术栈最相似的项目，直接参考其 `.kyb.md` 和踩坑记录。

## 已上船项目总览

| 项目 | 负责人 | 外链 | 状态 | MR | 工具层 | 依赖层 | 数据层 | 项目层 | 子模块 | DID |
|------|--------|------|------|-----|--------|--------|--------|--------|--------|-----|
| [dredge-lxk](#dredge-lxk) | 建行 | [repo](https://git.leyantech.com/marketing/dredge-lxk) | ✅ 收敛 | ✅ [!324](https://git.leyantech.com/marketing/dredge-lxk/-/merge_requests/324) | Java 8 + Maven + Ruby | Nexus | PostgreSQL + ClickHouse | JUnit 圈人服务 | click/party/datasets（深嵌套） | ❌ |
| [buyer-center](#buyer-center) | 泽坤 | [repo](https://git.leyantech.com/base-service/buyer-center) | ✅ 收敛 | ✅ [!76](https://git.leyantech.com/base-service/buyer-center/-/merge_requests/76) | Java 21 + Maven | Nexus | PostgreSQL | JUnit 买家中心 | party | ❌ |
| [buyer-server](#buyer-server) | 泽坤 | [repo](https://git.leyantech.com/base-service/buyer-server) | ✅ 收敛 | — | Java + Maven | Nexus | PostgreSQL | — | — | ❌ |
| [nova](#nova) | 马林 | [repo](https://git.leyantech.com/base-service/nova) | ✅ 收敛 | — | Java + Maven | Nexus | — | — | — | ❌ |
| [data-ant](#data-ant) | 马林 | [repo](https://git.leyantech.com/base-service/data-ant) | ✅ 收敛 | — | Java + Maven | Nexus（嵌套子模块） | — | 集成测试 | 嵌套子模块 | ❌ |
| [triggers-refund](#triggers-refund) | 泽坤 | [repo](https://git.leyantech.com/base-service/triggers-refund) | ✅ 收敛 | — | Java + Maven + JDK 代理坑 | Nexus | — | Kafka | — | ✅ |
| [form-manager](#form-manager) | 泽坤 | [repo](https://git.leyantech.com/base-service/form-manager) | ✅ 收敛 | ✅ [!38](https://git.leyantech.com/base-service/form-manager/-/merge_requests/38) | Java 17 + Maven | Nexus | PostgreSQL | — | — | ❌ |
| [moneta](#moneta) | 泽坤 | [repo](https://git.leyantech.com/base-service/moneta) | ✅ 收敛 | ✅ [!237](https://git.leyantech.com/base-service/moneta/-/merge_requests/237) | Java 21 + Maven | Nexus（jOOQ） | PostgreSQL | — | — | ❌ |
| [rating-boost](#rating-boost) | 泽坤 | [repo](https://git.leyantech.com/base-service/rating-boost) | ✅ 收敛 | ✅ [!44](https://git.leyantech.com/base-service/rating-boost/-/merge_requests/44) | Java 21 + Maven | Nexus（jOOQ + Apollo + RocketMQ） | PostgreSQL | — | — | ❌ |
| [netflix](#netflix) | 方剑峰 | [repo](https://git.leyantech.com/marketing/netflix) | ✅ 收敛 | ✅ [!49](https://git.leyantech.com/marketing/netflix/-/merge_requests/49) | Java 8 + Maven | Nexus | — | — | — | ❌ |
| [recommendation-filter](#recommendation-filter) | 泽坤 | [repo](https://git.leyantech.com/recommendation/recommendation-filter) | ✅ 收敛 | ✅ [!205](https://git.leyantech.com/recommendation/recommendation-filter/-/merge_requests/205) | Java 8 + Maven | Nexus | — | gRPC + Kafka | — | ❌ |
| [recommendation-config](#recommendation-config) | 泽坤 | [repo](https://git.leyantech.com/recommendation/recommendation-config) | 🟡 Round 2 | ✅ [!298](https://git.leyantech.com/recommendation/recommendation-config/-/merge_requests/298) | Java 8 + Maven | Nexus（leyan-proto 95MB） | MySQL/SQLite（测试用嵌入式） | JUnit 50 测试（3 个已知失败） | — | ❌ |
| [recommendation-finder](#recommendation-finder) | 郑一飞 | [repo](https://git.leyantech.com/recommendation/recommendation-finder) | ✅ 收敛 | ✅ [!172](https://git.leyantech.com/recommendation/recommendation-finder/-/merge_requests/172) | Java + Maven | Nexus | — | — | — | ❌ |
| [peroration](#peroration) | 杨孙学 | [repo](https://git.leyantech.com/base-service/peroration) | ✅ 收敛 | ✅ [!76](https://git.leyantech.com/base-service/peroration/-/merge_requests/76) | Java 8 + Maven | Nexus | PostgreSQL | — | — | ❌ |
| [lighthouse](#lighthouse) | — | [repo](https://git.leyantech.com/base-service/lighthouse) | ✅ 收敛 | ✅ [!36](https://git.leyantech.com/base-service/lighthouse/-/merge_requests/36) | Java 8 + Maven | Nexus（leyan-proto 107MB） | PostgreSQL + jOOQ | JUnit 60 tests 灯塔助手 | — | ❌ |
| [sidecar](#sidecar) | 王龙 | [repo](https://git.leyantech.com/support/sidecar) | ✅ 收敛 | ✅ [!6](https://git.leyantech.com/support/sidecar/-/merge_requests/6) | Python 3.11 + uv | Nexus（PyPI） | PostgreSQL | pytest 88 tests | — | ❌ |
| [citi](#citi) | AI | [repo](https://git.leyantech.com/ai/citi) | 🟡 Round 1 | — | Python 3.11 + uv | Nexus PyPI | SQLite (测试) | pytest 228 tests | .arc-extensions | ❌ |
| [business-rule](#business-rule) | AI | [repo](https://git.leyantech.com/ai/business-rule) | 🟡 Round 1 | — | Python 3.10 + Maven | Nexus (Maven) + PyPI | — | JUnit 集成测试 | .arc-extensions | ❌ |

> **负责人数据来源**: ntsb `resources/dbs.toml` 的 maintainer 字段 + 各项目 Git commit 贡献度交叉验证。添加新项目时同步更新。

## 快速定位参考项目

### 按 JDK 版本

| JDK | 项目 | 备注 |
|-----|------|------|
| **8** | dredge-lxk, lighthouse | 需手动 `mise install java@corretto-8`（parent POM 强制 `1.8`） |
| **17** | form-manager | Lombok 兼容性 |
| **21** | buyer-center, buyer-server, nova, data-ant, triggers-refund | kyb-base 预装 |

### 按数据库

| 数据库 | 项目 |
|--------|------|
| **仅 PostgreSQL** | buyer-center, buyer-server, nova, data-ant, triggers-refund, lighthouse |
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
- **MR**: https://git.leyantech.com/marketing/dredge-lxk/-/merge_requests/324（✅ merged）
- **关键踩坑**:
  - JDK 8 需手动 `mise install`
  - ClickHouse 24.2 容器必须（host CK 25.1 不兼容 JSON 类型）
  - 测试非幂等（`ON CONFLICT DO NOTHING`），重跑前 truncate
  - 子模块 `click` 嵌套 6+ 层
- **推荐参考场景**: Java 8 + ClickHouse 项目、子模块深嵌套项目

### buyer-center

- **描述**: 买家中心服务
- **MR**: https://git.leyantech.com/base-service/buyer-center/-/merge_requests/76（✅ merged）
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
- **MR**: !38（✅ merged）
- **关键踩坑**: Lombok 1.18.22 与 Java 21 不兼容（NoSuchFieldError），需切 Java 17
- **推荐参考场景**: Lombok + Java 17 项目

### moneta

- **描述**: hamilton-sdk 消费方，淘系买家标签服务，5 模块
- **MR**: !237（✅ merged）
- **关键踩坑**: jOOQ codegen class version 61.0 vs 52.0 冲突，DID 需手动装 Maven
- **推荐参考场景**: jOOQ codegen + multi-module 项目

### rating-boost

- **描述**: hamilton-sdk 消费方，5 模块，jOOQ codegen，Apollo + RocketMQ
- **MR**: !44（✅ merged）
- **关键踩坑**: mise 回退（JDK 21→17→8 切换），DID 需手动装 PG/pip/Maven，子模块 doudian-buyer
- **推荐参考场景**: jOOQ codegen + Apollo/RocketMQ 项目

### netflix

- **描述**: hamilton-sdk 消费方，4 模块，无 DB
- **MR**: !49（✅ merged）
- **关键踩坑**: JaCoCo 0.8.8 不兼容 JDK 21 class files，3 tests passed
- **推荐参考场景**: 无 DB + JaCoCo 项目

### recommendation-filter

- **描述**: hamilton-sdk 消费方，gRPC + Kafka，无 DB，12 tests
- **MR**: !205（✅ merged）
- **关键踩坑**: Java 21→8 切换（gRPC 不兼容 JDK 21），DID 验证通过
- **推荐参考场景**: gRPC + Kafka 项目

### recommendation-finder 🏆

- **描述**: hamilton-sdk 消费方，无 DB，纯 Mock 测试，23 tests
- **MR**: !172（✅ merged）
- **关键踩坑**: 无卡点 — 全 4 轮收敛，首位完成
- **推荐参考场景**: 纯 Mock 测试、极简项目

### peroration

- **描述**: store-home 店铺首页服务，Java 8 + Maven，jOOQ codegen，Kafka + Redis
- **MR**: !76（✅ merged）
- **关键踩坑**: JAVA_HOME 需显式 export、mig25 status 不存在（用 psql 替代）
- **推荐参考场景**: Java 8 + jOOQ codegen + 多外部服务（Kafka/Redis）项目

### lighthouse

- **描述**: 灯塔助手服务，Java 8 + Maven + PostgreSQL + jOOQ codegen + Jooby + gRPC + Apollo，4 模块，60 tests
- **MR**: [!36](https://git.leyantech.com/base-service/lighthouse/-/merge_requests/36)（✅ merged）
- **关键踩坑**:
  - JDK 8 必须（parent POM `com.leyantech:base:1.0.23` 强制 `<requireJavaVersion>1.8</requireJavaVersion>`）
  - Lombok 1.18.12 与 JDK 17+ 不兼容（`IllegalAccessError`）
  - `JAVA_HOME` 需显式 export（`export JAVA_HOME=$(mise where java@corretto-8)`）
  - leyan-proto 1.41.66 达 107MB，大文件下载可能因网络不稳定失败
  - mig25 需要从项目目录执行才能读取 `m25.yml`
- **推荐参考场景**: Java 8 + Maven multi-module + jOOQ codegen + Jooby + gRPC 项目

### recommendation-config

- **描述**: 推荐服务的配置管理，Java 8 + Maven 4 模块（config-core/rpc/web/consumer），生产 MySQL，测试 SQLite（嵌入式），gRPC + Kafka consumer + Jooby + Lombok 1.18.8
- **MR**: [!298](https://git.leyantech.com/recommendation/recommendation-config/-/merge_requests/298)（🟡 Round 2 进行中）
- **关键踩坑**:
  - JDK 8 必须（Lombok 1.18.8 + JaCoCo 0.8.4 + gRPC `Field.modifiers` 反射均不兼容 JDK 9+）
  - leyan-proto-1.38.45.jar 95MB，首次下载可能因 socks5 代理超时中断
  - 测试非幂等：CategoryServiceImplTest.testGet 和 ConfigHandlerTest.testScene 有数据残留问题
- **推荐参考场景**: Java 8 + gRPC + 测试用嵌入式 DB（SQLite）项目

### sidecar

- **描述**: 京东服务商辅助工具，Python 3.11 + uv + PostgreSQL，88 tests
- **MR**: !6（✅ merged）
- **关键踩坑**: `uv python pin` 后需手动验证 .python-version 文件已创建
- **推荐参考场景**: Python + uv 项目、纯 Python 无明显 tech-debt 项目

### citi

- **描述**: 商家意图管理（NLP 分类/聚类）服务。Python 3.11 + uv + Flask + SQLAlchemy + Celery + Kafka + gRPC，228 tests
- **MR**: 待创建
- **关键踩坑**:
  - **grpcio 1.43.0 arm64 不兼容**：`leyan-proto`/`common-libs` 硬依赖 grpcio==1.43.0，该版本无 arm64 linux 二进制 wheel 且源码不兼容 GCC 13。解决方案：`pip install 'grpcio==1.80.0'` + 内部包用 `--no-deps`
  - **kyb-base Python 版本不满足**：项目要求 >=3.11，kyb-base 只有 3.10。需 `uv python pin 3.11.15`
  - **librdkafka-dev 缺失**：confluent-kafka 编译需要 `sudo apt-get install -y librdkafka-dev`
  - **protobuf 版本兼容**：leyan-proto 的 pb2 文件需 protobuf 3.x，新 protobuf 5.x 不兼容。`pip install 'protobuf>=3.20,<4'`
  - **pip install -e . 失败**：pyproject.toml 缺少 `[tool.setuptools.packages.find]` 配置。临时方案用 `PYTHONPATH=$PWD`
  - **测试完全自包含**：SQLite :memory: + mock 外部服务，无需 PG/Redis/Kafka
- **推荐参考场景**: Python + uv 项目、重度 gRPC/Proto 项目、arm64 环境踩坑参考

### business-rule

- **描述**: AI NLP 规则管理。Python + Airflow + Maven(integration-test) 混合项目。
- **MR**: 待创建
- **关键踩坑**:
  - Nexus 403：容器 IP 192.168.215.0/24 不在 Nexus 白名单，阻断 Maven 编译和测试
  - PyYAML 6.0+ `yaml.load()` 不兼容（项目代码用无参 `yaml.load()`）
  - oss2 未预装，Airflow 脚本需要
  - 无数据库依赖
- **推荐参考场景**: Python + Maven 混合项目、项目有 IP 白名单限制的项目

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
| 12 | Nexus 403 IP 白名单 | business-rule | 首次遇到 IP 限制的项目 | 宿主机将 `192.168.215.0/24` 加入 Nexus 白名单 |
