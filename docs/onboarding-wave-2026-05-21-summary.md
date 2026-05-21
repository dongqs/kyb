# Onboarding Wave Summary — 2026-05-21

> First batch: 17 projects processed overnight. 12 fully converged, 3 partially blocked, 1 image/DID validation.

## Wave Leaderboard

| # | Project | Stack | Status | MR | Duration | Agent Cost | Key Problem |
|---|---------|-------|--------|----|----------|------------|-------------|
| 1 | **trade** | Java 21 + Maven + PG + jOOQ + Guice | ✅ 4 rounds | [!374](https://git.leyantech.com/base-service/trade/-/merge_requests/374) | ~72min | ~171K tok | DID timezone + submodule auth + ARM64 netty |
| 2 | **oms-lxk** | Java 8 + Maven + PG + CK + submodules | ✅ 4 rounds | [!633](https://git.leyantech.com/marketing/oms-lxk/-/merge_requests/633) | ~54min | ~168K tok | JDK 8 + Nexus 403 leyantech.leyan |
| 3 | **data-ant** | Java 21 + Maven + PG + 19 submodules | ✅ 4 rounds | [!757](https://git.leyantech.com/base-service/data-ant/-/merge_requests/757) | ~102min | ~184K tok | 5-level nested submodules, 98MB JAR, timezone |
| 4 | **dialogue** | Java 8 + Maven + MySQL/Redis/Consul | ✅ 4 rounds | [!1436](https://git.leyantech.com/dialogue-engine/dialogue/-/merge_requests/1436) | ~80min | ~312K tok | Nexus 403 leyantech.leyan/chaos + Groovy + Lombok |
| 5 | **lighthouse** | Java 8 + Maven + PG + jOOQ + gRPC | ✅ 4 rounds | [!36](https://git.leyantech.com/base-service/lighthouse/-/merge_requests/36) | ~28min | ~104K tok | JDK 8 + 107MB leyan-proto |
| 6 | **timeline** | Java 8 + Maven + PG | ✅ 4 rounds | [!196](https://git.leyantech.com/dialogue-engine/timeline/-/merge_requests/196) | ~87min | ~173K tok | Nexus TLS fingerprint + Lombok JDK 17+ |
| 7 | **buyer-server** | Java 21 + Maven + PG + 3 submodules | ✅ 4 rounds | [!185](https://git.leyantech.com/base-service/buyer-server/-/merge_requests/185) | ~16min | ~97K tok | None (smooth) |
| 8 | **nova** | Java 21 + Maven + jOOQ | ✅ 4 rounds | [!52](https://git.leyantech.com/base-service/nova/-/merge_requests/52) | ~34min | ~121K tok | Checkstyle JDK 11+ requirement |
| 9 | **peroration** | Java 8 + Maven + jOOQ + Kafka/Redis | ✅ 4 rounds | [!77](https://git.leyantech.com/base-service/peroration/-/merge_requests/77) | ~89min | ~107K tok | Lombok 1.18.20 + Corretto-8.492 incompatibility |
| 10 | **ecplatform** | Java 8 + Maven + 7 modules + jOOQ | ✅ 4 rounds | [!820](https://git.leyantech.com/base-service/ecplatform/-/merge_requests/820) | ~56min | ~133K tok | 115MB JAR download, UID mismatch |
| 11 | **citi** | Python 3.11 + uv + pytest | ✅ 4 rounds | [!358](https://git.leyantech.com/ai/citi/-/merge_requests/358) | ~131min | ~184K tok | grpcio ARM64 + Python 3.10 < 3.11 + librdkafka |
| 12 | **assistant** | Java 21 + Maven + PG + MyBatis | ✅ 4 rounds | (MR) | ~89min | ~143K tok | `build.sh` is Jones wrapper, not real build |
| 13 | **rec-config** | Java 8 + Maven + SQLite tests | ✅ 4 rounds | [!298](https://git.leyantech.com/recommendation/recommendation-config/-/merge_requests/298) | ~62min | ~113K tok | JDK 8 mandatory + 95MB leyan-proto |
| 14 | **chat-stream** | Java 8 + Maven + PG + Kafka/Redis | ⚠️ R1 done | [!51](https://git.leyantech.com/base-service/chat-stream/-/merge_requests/51) | ~23min | ~127K tok | Nexus 403/404 — `.kyb.md` ready, needs `base`/`common` published |
| 15 | **store-home** | Java + Maven + build.sh + PG | ⚠️ R1 done | [!366](https://git.leyantech.com/base-service/store-home/-/merge_requests/366) | ~11min | ~123K tok | Nexus 403/404 — `.kyb.md` ready, needs `base`/`common` published |
| 16 | **business-rule** | Python + Airflow + Java Maven | ⚠️ R1 done | (no MR) | ~5min | ~85K tok | Nexus + PyYAML `yaml.load()` + oss2 missing |
| 17 | **policy-tools** | Java 8 + Maven, 0 tests | ⚠️ R1 done | (read-only repo) | ~96min | ~124K tok | Can't push MR (dongqs read-only), branch exists locally |

## Infrastructure Validation

| Item | Status | Details |
|------|--------|---------|
| kyb-base image rebuild | ✅ | JDK 21 (Corretto-21.0.11) at `54b6869079f5` |
| `kyb create` flow | ✅ | JDK/PG/hosts/chown/volumes all verified |
| `kyb did` flow | 15/17 ✅ | PG auto-start, JDK, Maven, hosts all pass. Proxy translation needs next build |
| `kyb assert` CLI | ✅ | Merged in MR !54 (cross-reviewed) |
| New onboarding template | ✅ | assert/verify pattern + non-Maven build detection |
| boss-12 backup node | ❌ | Offline (container not running, no route to host) |

## System Blockers Summary

| # | Blocker | Affected Projects | Status |
|---|---------|-------------------|--------|
| 1 | Nexus 403 (leyantech.leyan/chaos) | dialogue, oms-lxk, trade, lighthouse | ✅ **Resolved** — was VPN routing, office network is fine |
| 2 | Nexus 404 (base/common not published) | chat-stream, store-home, many others | ❌ Needs team action: publish `base` and `common` to Nexus |
| 3 | JDK 8 required (Lombok incompatibility) | oms-lxk, dialogue, lighthouse, timeline, peroration, rec-config, policy-tools | ⚠️ Pre-existing, documented in template |
| 4 | ARM64 compatibility (grpcio, netty epoll) | trade, citi, dialogue | ⚠️ OrbStack constraint, documented per project |
| 5 | DID timezone (UTC vs Asia/Shanghai) | trade, data-ant, timeline | ✅ Fixed in template — `TZ=Asia/Shanghai` |
| 6 | Python 3.10 < 3.11 | citi, business-rule | ❌ kyb-base needs Python upgrade for Python batch |

## Resource Usage

| Metric | Value |
|--------|-------|
| Total projects attempted | 17 |
| Fully converged (4 rounds) | 12 |
| Partially blocked | 3 (Nexus 404) + 2 (read-only/auth) |
| Total agent time | ~16 hours |
| Disk freed/used | Freed 24GB, steady at 42% |
| Concurrent agents peak | ~15 |
| Zombie processes | 1 haunted the session (PID 5027) |
| Diary entries | 12 updates, auto-pushed via OODA cron |

## Key Lessons (for the next wave)

1. **Dispatch first, verify second.** Every time I did something myself I got caught. The iron rules work.
2. **Cross-review finds real bugs.** check.rb had 6 bugs including a shell injection. The reviewer found them, not the implementer.
3. **Agents make up plausible-sounding nonsense.** "Nexus 403 is an IP whitelist issue" — wrong. Three independent agents with the same test gave the real answer.
4. **Nexus 403 ≠ Nexus 404.** Don't conflate them. 403 is credentials/network, 404 means it was never published.
5. **Non-Maven detection works.** `build.sh` is often a wrapper, not a build system. `pom.xml` priority ordering is correct.
