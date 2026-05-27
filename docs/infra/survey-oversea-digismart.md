# Infrastructure Survey: Oversea (跨境) & Digismart (飞梭)

> Generated: 2026-05-22
> Source: GitLab API v4, CI config analysis, pom.xml/requirements.txt inspection

## Overview

| Group | Projects (total) | Key Backend Services | Note |
|-------|------------------|---------------------|------|
| **Oversea** | 165 (across 6 subgroups) | ~25 core Java services | Biggest group, cross-border e-commerce |
| **Digismart** | 200 (~80 core + 120 leybots) | ~14 core + many RPA bots | RPA automation, invoice, robot process |

## Local Clone Status

**No oversea or digismart projects are cloned locally.** Only 9 unrelated repos exist:
`buyer-center`, `chat-stream`, `dredge-lxk`, `kyb`, `lighthouse`, `oms-lxk`, `recommendation-config`, `timeline`, `trade`

---

## Oversea (跨境) Group

### Key Projects (user-specified)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK | Build | Notes |
|---------|-------|------------|----|-------|-------|----|-----|-------|-------|
| oversea-door | oversea | Java/Maven/Spring | -- | jedis | -- | -- | -- | maven | gateway/api entry; MySQL dep |
| overseaim-store-home | oversea | Java/Maven/Spring | -- | jedis | kafka | -- | 8 | maven + sonar | store-home service; MySQL |
| oversaim-hi-manager | oversea | Java/Maven/Spring | -- | -- | kafka | -- | 21 | maven + sonar | hi manager; MySQL, mybatis-plus |
| overseaim-hi | oversea | Java/Maven/Spring | -- | -- | -- | -- | -- | maven + sonar | MySQL, mybatis, ES |
| overseaim-trade | oversea | Java/Maven/Spring | -- | jedis | kafka | -- | -- | maven | trade service; MySQL |
| overseaim-item | oversea | Java/Maven/Spring | -- | jedis | kafka | -- | -- | maven | item service; MySQL |
| oversea-tunnel | oversea | Java/Maven/Spring | -- | -- | kafka | -- | 21 | maven + sonar | tunnel service; mybatis-plus, MySQL |
| oversea-policy | oversea | Java/Maven/Spring | -- | -- | kafka | -- | 1.8 | maven + sonar | policy engine; mybatis-plus, MySQL |
| oversea-agent | oversea | Java/Maven/Spring | -- | -- | kafka | -- | 1.8 | sonar-java | AI agent; MySQL, mybatis |
| oversea-dialogue | oversea | Java/Maven/Spring | -- | -- | kafka | -- | -- | sonar-java | dialogue engine; |
| overseaim-second-shot | oversea | Java/Maven | -- | -- | kafka | -- | -- | maven | |
| oversea-knowledge-builder | oversea | Java/Maven | -- | redis | -- | -- | 21 | maven + sonar | knowledge base builder |
| oversea-hi-vts | oversea | Java/Maven | -- | -- | kafka | -- | -- | maven + sonar | VTS service |
| oversea-prompt | oversea | Java/Maven | -- | -- | -- | -- | -- | maven + sonar | prompt management |
| oversea-review-analyzer | oversea | Java/Maven | -- | -- | -- | -- | -- | maven + sonar | review analysis |
| oversea-llm-config | oversea | Java/Maven | -- | -- | -- | -- | -- | maven + sonar | LLM configuration |

### Subgroup Projects

| Project | Group | Tech Stack | Notes |
|---------|-------|------------|-------|
| hermes-agent | oversea | Java/Maven | -- |
| hermes-skills | oversea | Java/Maven | -- |
| agent-bridge | oversea | Java/Maven | -- |
| themis | oversea | Java/Maven | -- |
| chatplusai-open-api | oversea | Python 3.11+ | chatbot AI API platform |
| shopgenius-auto-optimize | oversea | Java/Maven | Shopify auto-optimize |
| jolect-claw-go | oversea | Go (expected) | Go project by name |
| jolect-claw | oversea | Java/Maven | claw tool |
| oversea-agent-mcp | oversea | Java/Maven | MCP agent |
| oversea-agent-tools | oversea | Java/Maven | agent tools |
| oversea-bfrst | oversea | Java/Maven | -- |
| oversea-i18n | oversea | Java/Maven | i18n service |
| item-cluster | oversea | Java/Maven | redis, kafka |
| oversea-buyer-tag | oversea | Java 1.8/Maven | redis, kafka |
| oversea-apidoc | oversea | Java/Maven | API doc service |
| oversea-upload-bridge | oversea | Java/Maven | upload bridge |
| oversea-asr | oversea | Java/Maven | ASR service |
| oversea-rpa | oversea | Java/Maven | RPA |

### Subgroups (projects count)

| Subgroup | Projects | Typical Tech |
|----------|----------|-------------|
| oversea/front | 20 | Frontend (React/TS) |
| oversea/python | 5 | Python |
| oversea/shopify | 35+ | Mix Java/Python/Node |
| oversea/wa | 2 | WhatsApp services |
| oversea/rpa | 1 | 1688-item |

### Marketing Group (related)

| Project | Tech | Notes |
|---------|------|-------|
| oversea_mkt_door | Python 3.8 | MySQL-backed |
| oversea_mkt_duoduoyun | -- | -- |
| oversea_mkt_ip_proxy | Python 3.8 | MySQL-backed |
| overseas-marketing | -- | -- |

---

## Digismart (飞梭) Group

### Key Projects (user-specified)

| Project | Group | Tech Stack | PG | Redis | Kafka | CK | JDK/Python | Build | Notes |
|---------|-------|------------|----|-------|-------|----|------------|-------|-------|
| robot-processor | digismart | Python 3.11 / aiokafka / Flask | -- | fakeredis | aiokafka | -- | 3.11 | sonar-python + mypy | Core robot process; alembic, celery likely |
| invoice-robot-cloud | digismart | Node.js (Bun) / TypeScript | -- | -- | -- | -- | Bun | oxlint/oxfmt | Frontend or lightweight service |
| feisuo-app | digismart | Private -- API blocked | -- | -- | -- | -- | -- | -- | API 403; likely Electron/desktop app |
| feisuo-work-order | digismart | Private -- API blocked | -- | -- | -- | -- | -- | -- | API 403; work order system |
| feisuo-bot | digismart | Unknown | -- | -- | -- | -- | -- | -- | README: feisuo-bot |
| feisuo-tests | digismart | Python (test framework) | -- | -- | -- | -- | -- | -- | Integration tests |
| llm-wiki | digismart | Unknown (no build files) | -- | -- | -- | -- | -- | -- | No CI / build files found |
| robot-transfer | digismart | Python 3.8 / aliyun SDK | -- | -- | -- | -- | 3.8 | sonar-python | Robot transfer service |
| robot-types | digismart | Python 3.11 / pypi | -- | -- | -- | -- | 3.11 | publish_pypi | Type definitions/RobotType DSL |
| dgt-risk-control | digismart | Python 3.8 / pytest | -- | -- | -- | -- | 3.8 | sonar-python | Risk control; MySQL |
| dgt-bi-server | digismart | Java/Maven | -- | -- | -- | -- | -- | sonar-java + deploy-flow | BI server |
| dgt-global-search | digismart | Java/Maven | -- | -- | -- | -- | -- | sonar-java + deploy-flow | ES-backed search |
| digismart-alipay | digismart | Java/Maven/Spring | -- | redis | kafka | -- | -- | sonar-java | Alipay integration; MySQL |
| digismart-item | digismart | Java/Maven/Spring | -- | redis | kafka | -- | -- | sonar-java | Item service |
| digsmart-metabase | digismart | Docker / Metabase v0.44.4 | -- | -- | -- | -- | -- | -- | Wrapper around metabase image |
| theia | digismart | Java 8 / Spring Boot 2.1.1 | PG | -- | -- | -- | 1.8 | sonar-java | MySQL, mybatis |
| mola-service | digismart | Frontend (fed-web-preset) | -- | -- | -- | -- | -- | fed-web-preset | TypeScript/React |
| robot-erp | digismart | Java/Maven | -- | -- | -- | -- | -- | -- | ERP service |
| angelina | digismart | -- | -- | -- | -- | -- | -- | -- | -- |
| jos | digismart | -- | -- | -- | -- | -- | -- | -- | -- |

### Digismart Subgroup: rpa/lebots (RPA bots -- ~60+ projects)

| Category | Count | Typical Tech | Notes |
|----------|-------|-------------|-------|
| lebots (RPA bot scripts) | ~60 | Python / RobotFramework | PD D, Taobao, Douyin automation |
| Support services | ~15 | Python / Java | rcc, rpa-gateway, rpa-worker, rpa-control |
| Feishuo scripts | ~5 | Python | feisuo-scripts, add-goods-batch, etc. |

---

## Infrastructure Patterns

### Common Dependencies (from pom.xml analysis)

| Dependency | Oversea Prevalence | Digismart Prevalence |
|------------|-------------------|---------------------|
| MySQL | Nearly all Java services | Most Java services |
| PostgreSQL | Rare | theia uses PG |
| Redis (jedis/lettuce) | ~70% of services | ~50% of services |
| Kafka / spring-kafka | ~70% of services | ~30% of services |
| ClickHouse | None detected | None detected |
| Elasticsearch | overseaim-hi, item-cluster | dgt-global-search |
| MyBatis / MyBatis-Plus | Most Java services | Some Java services |
| Nacos | Not detected in CI | Not detected in CI |
| RocketMQ | Not detected in CI | rocketmq-py (Python client) |

### Java Version Distribution

| JDK | Oversea (sampled) | Digismart (sampled) |
|-----|--------------------|---------------------|
| Java 8 (1.8) | oversea-agent, oversea-policy, buyer-tag | theia |
| Java 21 | oversea-tunnel, oversaim-hi-manager, knowledge-builder | -- (not detected) |
| Undetermined | Most others (not specified in pom.xml) | digismart-alipay, digismart-item |

### Build Systems

| Build | Oversea | Digismart |
|-------|---------|-----------|
| Maven (mvn) | ~80% of backend services | ~40% (Java services) |
| sonar-java template | Standard for all Java services | Standard for Java services |
| sonar-python template | For Python subgroup | For Python services |
| publish_jar template | Tag-based publishing | -- |
| deploy-flow template | -- | dgt-bi-server, dgt-global-search |
| fed-web-preset | Frontend subgroup | mola-service |
| publish_pypi | -- | robot-types |

### CI Runner Tags

- **lab**: Common for oversea Java services
- **docker**: Some services use Docker runners
- **digismart-office-dev-docker**: Exclusive to digismart Python services
- Some projects use kyb-infra-sing-box proxy for network access

### Non-functional Observations

1. **API blocked**: feisuo-app, feisuo-work-order are private (403 on API)
2. **No CI config**: llm-wiki, invoice-robot-cloud (Node.js project likely uses different CI)
3. **No local clones exist** for either group -- all projects exist only on GitLab
4. **No Dockerfiles** detected in any of the sampled projects (CI uses pre-built images)
5. **No kubernetes manifests** found in sampled repos (k8s likely managed externally)
6. **No ClickHouse** dependency detected in any sampled project

---

## Summary

### Oversea
- **Dominant stack**: Java 8/21, Spring Boot (Maven), MySQL, Redis, Kafka
- **Subgroups**: front (React), python, shopify (multi-lang), wa (WhatsApp)
- **CI pattern**: `sonar-java.gitlab-ci.yml` template, lab-tagged runners
- **Key missing infra**: No PostgreSQL, no ClickHouse, no RocketMQ detected
- **JDK migration**: Some newer services on Java 21, legacy on Java 8

### Digismart
- **Dual stack**: Python 3.8/3.11 for RPA/robot services, Java 8 for enterprise services
- **Subgroups**: rpa/lebots (60+ RPA scripts), rpa/ (support services)
- **CI pattern**: `sonar-python` for Python, `sonar-java` for Java, custom runners
- **Unique traits**: Uses its own Docker runner pool (digismart-office-dev-docker)
- **Key missing infra**: No common message queue standard -- Kafka for Java, aiokafka for Python
- **Private projects**: feisuo-app and feisuo-work-order inaccessible via API

### Action Items for Infra Setup
1. **Clone strategy**: Plan for batch-cloning ~40 key projects (25 oversea + 14 digismart)
2. **Container sizing**: Java services need JDK 8 and 21; Python services need 3.8 and 3.11
3. **Service dependencies**: Ensure MySQL, Redis, Kafka are available for local dev
4. **CI compatibility**: Lab runners vs digismart-office-dev-docker runners differ
