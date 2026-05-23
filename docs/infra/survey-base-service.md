# Base-Service Group Infrastructure Survey

> Discovery date: 2026-05-22
> Scope: Infrastructure requirements for onboarding agents.
> DO NOT build or test based on this doc -- survey only.

## Survey

| Project | Tech Stack | PG Ver | Redis | Kafka | CK | JDK | Build | Deploy | Notes |
|---------|-----------|--------|-------|-------|-----|------|-------|--------|-------|
| trade | Java+Maven+JOOQ+Apollo+gRPC | 14 | No | No | No | 21 | mvn | artifact | multi-module (core/data-service/application); submodule `Norland` for mig25 migrations; ArcLint template |
| chat-stream | Java+Maven+Kafka+Redis+ONS+TaobaoSDK | No CI service | Yes (chaos-redis) | Yes (chaos-kafka) | No | 8 | mvn | lain | polyglot message ingestion (JST, Aliyun, taobao); multiple workers per platform; parent `bi-dependency:2.0.0-SNAPSHOT` |
| lighthouse | Java+Maven+JOOQ+Apollo | 15.3 | No | No | No | 8 (inferred) | mvn | artifact | multi-module (assemble/lighthouse/lighthouse-web/lighthouse-data); mig25; JUnit 4 |
| store-home | Java+Maven+JOOQ+Apollo | 15.3 | No | No | No | 21 | mvn | artifact | multi-module (7 mods: consumer/web/data/job); MySQL connector dep (kafka-client commented out); mig25; ERD pages |
| assistant | Java+Maven+JOOQ/MyBatis+Apollo+pgvector | 15 (pgvector) | No | No | No | 21 | mvn | lain | multi-module (6 mods); MyBatis+JOOQ dual ORM; pgvector for AI features; multi-platform (taobao) |
| ecplatform (EC Platform) | Java+Maven+Redis+Kafka(gRPC proxy)+Apollo | 15.3 | Yes (redisson) | Yes (kafka-grpc-proxy-client) | No | 8 | mvn | lain | 6 modules; per-platform lain configs (dy/jd/ks/pdd/tb/wx/xhs); item-structure service |
| treasure | Java+Maven+Spring Statemachine+Apollo | No | No | No | No | 8 (inferred) | none (sonar only) | lain | wraps basic APIs; calls other services (trade, manifest) via gRPC; no own DB; per-platform lain (dy/jd/ks/pdd/wx/xhs) |
| bot-trainer | Java+Maven+ClickHouse+Apollo | 15 (pgvector) | No | No | Yes (ck 0.3.2-p11) | 8 | mvn | lain | ClickHouse for analytics cluster; multi-platform (tb/dy/pdd/jd); consumer workers per platform; mig25; publish_jar template |
| picture-sync | Java+Maven+MySQL | No | No | No | No | 8 (inferred) | none (sonar only) | unknown | 7 modules; MySQL connector dep; minimal CI (sonar only); appears low-activity |
| base-service-common | Java+Maven (shared library) | 14 (for tests) | Yes (redis module) | Yes (fast-consumer) | No | 21 | mvn | publish_jar | 10 modules (common/redis/fast-consumer/ons-consumer/sqs-client/multi-jooq/middleware/...); shared infra library used by all base-service projects |

## Service Dependency Summary

### PostgreSQL
- **PG 14**: trade, base-service-common (test only)
- **PG 15.3**: lighthouse, store-home, ecplatform
- **PG 15 (pgvector)**: assistant, bot-trainer
- **No PG dependency**: treasure (no own DB), picture-sync (uses MySQL), chat-stream (uses PG at runtime via dependency but no PG service in CI)

### Redis
- **Yes**: chat-stream (chaos-redis), ecplatform (redisson-shaded), base-service-common (redis module)
- **No**: trade, lighthouse, store-home, assistant, treasure, bot-trainer, picture-sync

### Kafka / Message Queue
- **Yes (Kafka)**: chat-stream (chaos-kafka), ecplatform (kafka-grpc-proxy-client), base-service-common (fast-consumer module)
- **Yes (RocketMQ/ONS)**: chat-stream (ons-client), base-service-common (ons-consumer module)
- **Yes (AWS SQS)**: base-service-common (sqs-client module)
- **No**: trade, lighthouse, store-home, assistant, treasure, bot-trainer, picture-sync

### ClickHouse
- **Yes**: bot-trainer (clickhouse-jdbc 0.3.2-p11 http)
- **No**: all others

### MySQL
- store-home (mysql-connector-java)
- picture-sync (mysql-connector-java)
- assistant (mysql-connector-java in depMgmt)

### Other services / shared libraries
- **Apollo config center**: All Java projects use Apollo (com.ctrip.framework.apollo:apollo-client)
- **Sentry**: Most projects integrate Sentry error tracking (com.leyantech.common:sentry-wraps)
- **Nexus PyPI**: All projects with mig25 use Nexus as PyPI mirror
- **mig25**: All PG-using projects use mig25 for schema migrations
- **Registries**: `registry.leyantech.com/base-images/*`, `registry.leyantech.com/infra/*`

## JDK Version Distribution

| JDK | Projects |
|-----|---------|
| 21 | trade, store-home, assistant, base-service-common |
| 8 | chat-stream, lighthouse, ecplatform, treasure, bot-trainer, picture-sync |

## CI Patterns

### Templates used
- `sonar-java.gitlab-ci.yml` -- all projects (standard)
- `publish_jar.gitlab-ci.yml` -- trade, bot-trainer, base-service-common
- `.arc-lint-template` -- trade, base-service-common

### CI Images
- `registry.leyantech.com/base-images/maven-build:latest` -- older JDK8 projects
- `registry.leyantech.com/base-images/openjdk21-python-maven:3.11` -- newer JDK21 projects
- `registry.leyantech.com/base-images/java-build:latest` -- lain-deployed projects
- `registry.leyantech.com/base-images/openjdk21-arc-lint:latest` -- arc lint

## Deployment Patterns

### Artifact deployment (to Nexus/dist)
- trade, lighthouse, store-home publish `dist/*.jar` artifacts

### lain deployment (to Kubernetes)
- chat-stream, assistant, ecplatform, treasure, bot-trainer use lain.yaml
- Multi-platform configs: ecplatform (7 platforms), treasure (6 platforms), chat-stream (3+ platforms)
- Workers: most projects have multiple worker types (web, consumer, job, infra)

## Notes for Onboarding Agents

1. **JDK 8 projects** (chat-stream, lighthouse, ecplatform, treasure, bot-trainer, picture-sync) may need migration planning -- Leyantech is standardizing on JDK 21.
2. **lighthouse is local** at `~/projects/lighthouse` -- edit directly.
3. **chat-stream is local** at `~/projects/chat-stream` -- has its own README with architecture guidance.
4. **trade is local** at `~/projects/trade` -- has `CLAUDE.md` and detailed design prompts in `docs/design-prompts/`.
5. **Remote-only projects** (store-home, assistant, ecplatform, treasure, bot-trainer, picture-sync, base-service-common) -- use `glab` via socks5 proxy to fetch/edit.
6. **base-service-common** is a shared library, not a service -- changes here affect all other projects.
7. **ClickHouse** is only needed by bot-trainer -- all others use PostgreSQL.
8. **Redis** is needed only by chat-stream, ecplatform, and base-service-common itself.
