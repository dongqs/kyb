# Infrastructure Requirements Survey -- Remaining Project Groups

Survey date: 2026-05-22
Method: GitLab API (glab) project/repo inspection + local clone analysis

---

## Legend

| Service  | Meaning                          |
|----------|----------------------------------|
| PG       | PostgreSQL (version noted)       |
| CK       | ClickHouse                       |
| JDK      | Java Development Kit version     |
| Build    | Build system (Maven/Gradle/NPM)  |

---

## 1. dialogue-engine (4 projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| timeline | dialogue-engine | Java, Spring | 14 | - | - | - | 8 (openjdk8 runtime) | Maven | Timeline sync service. CI PG 14-alpine. Already cloned locally. |
| policy-tools | dialogue-engine | Java | - | - | - | - | - | Maven | Sonar-java template. No PG/Redis in CI. Library/policy tooling. |
| policy-codex-api | dialogue-engine | - | - | - | - | - | - | - | Private project (403). Could not inspect CI/pom. |
| (dialogue?) | dialogue-engine | - | - | - | - | - | - | - | No project literally named "dialogue" in group. Possible candidates: **gummy-candy** (empty project, no CI, last activity 2025-08) or **variable-graph** (Java, PG 14, Redis 7). |

**Additional projects in this group** (not listed in task but relevant): variable-graph (PG 14 + Redis 7), policy-core (Java), common-entry-service, policy-support, assistor (Java, ASR/dialogue assistance).

### PG Version: 14

---

## 2. ai (2 projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| business-rule | ai | NLU rules engine (Java test, Python/dsl rules) | - | - | - | - | - | Maven + Python | CI uses `push-trailer-with-diesel` image. Rules deployed as trailers to various platforms (pdd, jd, xhs, dy, ks). No persistent infra deps. |
| citi | ai | Python 3.11 | - | - | - | - | - | Python (pip/uv) | Sonar-python template. Config-based Python service. No PG/Redis/Kafka in CI. |

**PG Version: N/A** -- neither project uses PG in CI. Both are stateless rule/config services.

---

## 3. EP -- Engineering Productivity (3 projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| sites | ep | Node (Vue.js), pnpm | - | - | - | - | - | Yarn | Static site -- leyantech internal site list. No runtime infra deps. |
| create-backend | ep | Python (Django) | - | - | - | - | - | Pip | Deployapp -- creates backend services. Uses Celery, K8s deploy. CI uses K8S_CONFIG, no PG/Redis in CI. |
| common-libs | ep | Java multi-module | - | - | - | - | - | Maven | Central library: common-java, log-java, trailer, activity, gaia, venice, ledruid, etc. Uses kafka-clients 1.0.0, leyan-avro, leyan-proto. No PG/Redis in CI. |

**Additional**: common-libs-python (Python multi-module) also in EP group.

**PG Version: N/A** -- no persistent infra for CI.

---

## 4. Leyan (4 projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| leyan-proto | leyan | Python 3.8 + Java + Go 1.13 | - | - | - | - | - | Maven + Python setuptools | Core protobuf definitions for all gRPC services. CI: test-python (py3.8), test-java (maven), publish-golang (go1.13), publish pypi/jar. No PG/Redis/Kafka. |
| leyan-avro | leyan | Python + Java | - | - | - | - | - | Maven + Python setuptools | Avro schema definitions. CI: Python test with avro-tools, Java test with Maven. Publishes to pypi and nexus. No PG/Redis/Kafka. |
| leyan-proto-golang | leyan | Go | - | - | - | - | - | Go modules | Golang stubs generated from leyan-proto. CI file not found (no .gitlab-ci.yml, possibly uses Drone or Makefile). |
| java-example | leyan | Java | - | - | - | - | - | Maven | Example Java app. CI deploys to Alibaba SAE (serverless). No runtime infra deps. |

**PG Version: N/A** -- all library/example projects, no persistent infra.

---

## 5. Marketing (2 projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| oms-lxk | marketing | Java 8 | 14 | - | - | 24.2-alpine | 8 (openjdk8) | Maven | Order management system. CI: PG 14-alpine, ClickHouse 24.2-alpine. Already cloned locally. |
| oppo-v2 | marketing | - | - | - | - | - | - | - | Not cloned locally. Could not access CI (403/empty). Assumed similar to other lxk projects. |

**Additional projects in this group**: jd-lxk-forward, jd-mkt-quota, ratelimiter, lego-lxk, oppo-lxk, lxk-merchant-report, lxk-trade, ufs-lxk, dredge-lxk, guide-lxk, fishpond-es-nta -- mostly Java 8 Maven, some with PG 14, ClickHouse.

### PG Version: 14
### CK Version: 24.2-alpine

---

## 6. Recommendation (1 project)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| recommendation-config | recommendation | Java, MyBatis, MySQL | - | - | V (consumer) | - | - | Maven | Config management for recommendation service. Consumes Kafka topics. Uses MySQL (not PG). Modules: config-consumer, config-web, config-rpc, config-core. Already cloned locally. |

**PG Version: N/A** -- uses MySQL, not PostgreSQL.

---

## 7. RPA -- digismart/rpa/lebots (12+ projects)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|------|-----|-----|-------|-------|
| monitor_refund_new | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | rpa/release-robot template | RPA robot for refund monitoring. |
| pdd_feedback_central | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | rpa/release-robot template | PDD feedback central processing. |
| taobao_refund | digismart/rpa/lebots | Python + Robot | - | - | - | - | - | Windows builder (letszip) | Taobao refund robot. Windows-only CI. Uses robot_ci_utils submodule, Python zipping. |
| kuaishou_refund | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | No CI file found on master. |
| taofactory_return_refund | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | rpa/release-robot template | Taobao factory return refund. |
| pdd_bills_export | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | PDD bills export robot. |
| pdd_bad_review | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | PDD bad review handling. |
| douyin_ticket | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | Douyin ticket robot. |
| invoice-robot | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | Invoice processing robot. |
| pdd-goods-editor | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | PDD goods editor robot. |
| pdd_client_pay | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | PDD client payment robot. |
| pdd_reply_review | digismart/rpa/lebots | Robot Framework (Python) | - | - | - | - | - | - | PDD reply review robot. |

**Other lebots projects**: doudian-shop-metrics, youou_express_collection, pdd-shop-metrics, wdt_fc_invoice, huitun_data_capture_dy, huitun_data_capture, tao_work_order, zol_compare, taoba_grab, robot_sample_repo.

**PG Version: N/A** -- all RPA robots are stateless automation scripts.

**Summary**: The digismart/rpa/lebots group contains ~20 Robot Framework (Python-based) automation projects. Most use the shared `rpa/release-robot` CI template. Some older ones use Windows runners. None require databases or message queues -- they automate web/mobile interactions with ecommerce platforms.

---

## Summary Table (All Groups)

| Group | # Projects | Dominant Stack | PG | Redis | Kafka | CK | Notes |
|-------|-----------|----------------|----|-------|------|-----|-------|
| dialogue-engine | 20 | Java 8 (Maven) | 14 (some) | 7 (variable-graph) | - | - | Key infra deps: PG 14, Redis 7 |
| ai | 19 | Python + Java | - | - | - | - | Stateless rules/services |
| EP | 20+ | Java, Python, Node | - | - | - | - | Libraries, tooling, dev portals |
| leyan | 20 | Python, Java, Go | - | - | - | - | Proto/avro definitions, examples |
| marketing | 20 | Java 8 (Maven) | 14 | - | - | 24.2 | Key infra deps: PG 14, CK 24.2 |
| recommendation | 1 | Java, MySQL | - | - | V (consumer) | - | MySQL, not PG |
| RPA/lebots | 20 | Python/Robot Framework | - | - | - | - | Stateless, no infra deps |

## Key Findings

### Projects needing PG 14
- timeline (dialogue-engine)
- variable-graph (dialogue-engine) -- also needs Redis 7
- buyer-center (unknown group) -- PG 14, Java 21
- dredge-lxk (marketing)
- oms-lxk (marketing) -- also needs ClickHouse 24.2
- lighthouse (unknown group) -- PG 15.3, Java (maven-build)

### Projects needing PG 15
- lighthouse -- specifically PG 15.3

### Projects with no infra deps
- AI group: all stateless rules/ML services
- Leyan group: all library/definition projects
- EP group: libraries, docs, dev tooling
- RPA/lebots: all stateless automation scripts

### Persistent infra + stateful services summary
1. **PostgreSQL 14** -- most common, used by: timeline, variable-graph, buyer-center, dredge-lxk, oms-lxk, trade, chat-stream
2. **PostgreSQL 15.3** -- used by: lighthouse
3. **Redis 7** -- used by: variable-graph
4. **ClickHouse 24.2** -- used by: oms-lxk
5. **Kafka** -- used by: chat-stream (event source), recommendation-config (consumer), common-libs (kafka-clients dependency)
6. **MySQL** -- used by: recommendation-config

### Java version landscape
- **Java 8**: chat-stream, timeline, dredge-lxk, oms-lxk, most lxk projects
- **Java 21**: buyer-center, trade
- **Java 17**: commonly available in base images (maven-build:latest)
- **No JDK (Python/Node/Go)**: business-rule, citi, sites, create-backend, leyan-proto (Python), leyan-avro (Python), leyan-proto-golang (Go), all RPA robots
