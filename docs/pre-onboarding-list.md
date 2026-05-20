# Pre-Onboarding Candidate List

扫描范围: base-service、marketing、recommendation、leyan 等下已有项目的同组/关联项目。
生成时间: 2026-05-20
方法: GitLab API 拉取近 35 天有活动的项目 → 根目录文件列表 → CI 配置快速判断技术栈。

## P1 — 高优先级（有明确关联项目，技术栈相似）

| 项目 | 外链 | 技术栈 | 关联项目 | 理由 |
|------|------|--------|---------|------|
| **oms-lxk** | [repo](https://git.leyantech.com/marketing/oms-lxk) | Java + Maven + PG + **ClickHouse** | dredge-lxk | 同为 marketing/lxk 系，PG + CK 双库，子模块。dredge-lxk 的踩坑可直接复用 |
| **trade** | [repo](https://git.leyantech.com/base-service/trade) | Java + Maven + PG | Norland, data-ant | ntsb 中 `tb_trade` maintainer=马林，已有 .gitmodules + CLAUDE.md。同组已有 buyer-center 等大量参考 |
| **chat-stream** | [repo](https://git.leyantech.com/base-service/chat-stream) | Java + Maven + PG | buyer-center | 淘宝聊天数据流，buyer-center 的直接上游数据源 |
| **lighthouse** | [repo](https://git.leyantech.com/base-service/lighthouse) | Java + Maven + PG 15.3 | 通用 base-service | 标准 sonar-java 模版，PG，m25.yml 完备 |

## P2 — 中等优先级

| 项目 | 外链 | 技术栈 | 关联项目 | 理由 |
|------|------|--------|---------|------|
| **store-home** | [repo](https://git.leyantech.com/base-service/store-home) | build.sh + PG | peroration | peroration 就是 store-home 服务。ntsb 中 `tb_store_home_mysql` maintainer=王朵 |
| **recommendation-config** | [repo](https://git.leyantech.com/recommendation/recommendation-config) | Java + Maven + PG | recommendation-filter/finder | 同 recommendation 组，提供配置后台和 BI 接口 |
| **assistant** | [repo](https://git.leyantech.com/base-service/assistant) | build.sh（非 Maven） | 通用 base-service | 客服基础服务，AGENTS.md 说明已有 agent 支持 |

## P3 — 低优先级（需进一步确认）

| 项目 | 外链 | 技术栈 | 备注 |
|------|------|--------|------|
| **ecplatform** | [repo](https://git.leyantech.com/base-service/ecplatform) | E-Commerce Platform | 可能较大，需先确认范围 |
| **treasure** | [repo](https://git.leyantech.com/base-service/treasure) | API service | 信息不足 |
| **bot-trainer** | [repo](https://git.leyantech.com/base-service/bot-trainer) | — | 今日有活动，需进一步了解 |
| **picture-sync** | [repo](https://git.leyantech.com/base-service/picture-sync) | 图片同步服务 | 可能较简单 |

## 起始建议

从 **oms-lxk** 开始——它与 dredge-lxk 同系（marketing/lxk）、技术栈几乎一样（Java + Maven + PG + ClickHouse），dredge-lxk 的踩坑记录（JDK 8、CK 版本、子模块、测试幂等）可直接复用。预期 onboarding 速度会很快。

其次是 **trade**——已有 CLAUDE.md，说明已在用 agent 开发，接入成本低。
