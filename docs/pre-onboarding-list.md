# Pre-Onboarding Candidate List

全量扫描时间: 2026-05-20
范围: 所有 GitLab groups，近 31 天有活动的项目。
方法: `glab api groups/:id/projects` → 根目录文件列表 → CI 配置判断技术栈。

> 共 **~130 个项目**。已排除 fed/（前端）、oversea/front/（前端）、sre/（运维工具）、infrastructure/（基础设施）等非业务服务类项目。
> 剩余约 **70 个**。以下按 group 分组列出，标注快速扫描结果。

---

## base-service（10 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **trade** | Java + Maven + PG + 子模块 | 05-19 | ntsb maintainer=马林，已有 CLAUDE.md |
| **chat-stream** | Java + Maven + PG | 05-20 | buyer-center 上游数据源 |
| **lighthouse** | Java + Maven + PG 15.3 | 05-19 | sonar-java 模版，m25.yml |
| **store-home** | build.sh + PG | 05-19 | peroration 即此服务 |
| **assistant** | build.sh | 05-19 | 客服基础服务，AGENTS.md |
| **ecplatform** | — | 05-20 | E-Commerce Platform |
| **treasure** | — | 05-19 | API service |
| **bot-trainer** | — | 05-20 | 今日活跃 |
| **picture-sync** | — | 05-20 | 图片同步 |
| **base-service-common** | Java | 05-13 | 公共库 |

## marketing（2 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **oms-lxk** | Java + Maven + PG + ClickHouse | 05-19 | dredge-lxk 同系 |
| **oppo-v2** | — | 05-18 | 待进一步确认 |

## dialogue-engine（4 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **timeline** | Java + Maven + PG + 子模块 | 05-11 | ntsb maintainer=亚伟 |
| **policy-tools** | Java + Maven | 05-12 | sonar-java + publish_jar |
| **policy-codex-api** | — | 05-12 | 待确认 |
| **dialogue** | (无 pom.xml) | 05-20 | 核心 dialogue 服务 |

## recommendation（1 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **recommendation-config** | Java + Maven + PG | 04-09 | 同组已有 filter/finder |

## ai（2 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **business-rule** | Python + Airflow + 子模块 | 05-20 | 规则引擎 |
| **citi** | Python | 05-18 | 类目标注 |

## ep（3 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **sites** | — | 05-14 | 内部站点列表 |
| **create-backend** | — | 05-11 | 乐言 create 后端 |
| **common-libs** | Java + mkdocs | 04-10 | Java 基础库 |

## digismart / 飞梭（14 个）

> 飞梭业务线，多数为 Java/Python 服务

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **robot-processor** | — | 05-20 | 飞梭工单后台 |
| **invoice-robot-cloud** | — | 05-19 | 发票机器人 |
| **trade** | — | 05-13 | digismart 订单 |
| **feisuo-app** | — | 05-09 | 飞梭 APP |
| **llm-wiki** | — | 05-06 | LLM 知识库 |
| **robot-transfer** | — | 04-30 | 机器人转移 |
| **dgt-risk-control** | — | 04-29 | 风控 |
| **digismart-alipay** | — | 04-29 | 支付宝支付 |
| **robot-types** | — | 04-29 | 机器人类型 |
| **digsmart-metabase** | — | 04-28 | 元数据 |
| **theia** | — | 04-28 | BI 看板 |
| **dgt-bi-server** | — | 04-28 | BI 服务端 |
| **digismart-item** | — | 04-22 | 商品服务 |
| **mola-service** | — | 04-13 | Mola 网站服务 |

## digismart/rpa（12 个）

> RPA 机器人自动化脚本，多数较小

| 项目 | 最近更新 |
|------|---------|
| monitor_refund_new | 05-20 |
| pdd_feedback_central | 05-19 |
| taobao_refund | 05-19 |
| douyin_shipped_refund | 05-19 |
| taobao_return_refund | 05-19 |
| douyin_return_refund | 05-19 |
| tao_work_order | 05-17 |
| pdd_return_and_refund | 05-13 |
| pdd_reply_review | 05-12 |
| rpa-control | 05-18 |
| invoice-robot | 05-18 |
| rpa-libs | 05-14 |

## leyan（4 个）

| 项目 | 技术栈 | 最近更新 | 备注 |
|------|--------|---------|------|
| **leyan-proto** | Java + Maven | 05-20 | gRPC proto 定义 |
| **leyan-avro** | — | 05-20 | Avro 序列化 |
| **leyan-proto-golang** | Go | 05-19 | Go proto |
| **java-example** | Java | 04-22 | 示例项目 |

## oversea / 跨境（~25 个）

> 跨境的 Java 服务集群，与 base-service 功能域对等（trade/item/store-home/hi 等）

| 项目 | 最近更新 | 备注 |
|------|---------|------|
| oversea-door（网关） | 05-20 | 网关 |
| overseaim-store-home | 05-20 | 店铺管理（同 store-home） |
| oversaim-hi-manager | 05-20 | 会话配置（同 assistant） |
| overseaim-hi | 05-20 | 核心对话（同 dialogue） |
| overseaim-trade | 05-20 | 订单（同 trade） |
| overseaim-item | 05-15 | 商品（同 item） |
| oversea-tunnel | 05-15 | 聊天通道 |
| oversea-policy | 05-14 | Policy 服务（同 policy-tools） |
| oversea-agent | 05-18 | 问答代理 |
| oversea-dialogue | 05-18 | 海外版 dialogue |
| + ~15 个其他 | 04-23~05-20 | 各种辅助服务 |

## cto（1 个）

| 项目 | 最近更新 | 备注 |
|------|---------|------|
| refund-agent | 05-19 | CTO 办公室项目 |

## 按技术栈汇总

| 栈 | 数量 | 代表项目 | 参考项目 |
|----|------|---------|---------|
| **Java + Maven + PG** | ~15 个 | trade, lighthouse, timeline, recommendation-config | buyer-center, moneta |
| **Java + Maven + PG + CK** | 1 个 | oms-lxk | dredge-lxk |
| **Java + Maven（无 DB）** | ~3 个 | policy-tools, common-libs | netflix, recommendation-finder |
| **build.sh / shell** | ~3 个 | store-home, assistant | — |
| **Python** | ~3 个 | business-rule, citi | sidecar |
| **RPA 脚本** | ~12 个 | refund 系列 | — |

## 并发上船建议

按波次分组，每波 3-6 个项目（参考 race-live.md 的 6 并发模式）：

**第一波（Java Maven PG，技术栈最成熟）**：
1. oms-lxk → 参考 dredge-lxk（CK + 子模块）
2. trade → 已有 CLAUDE.md
3. lighthouse → 标准 sonar-java
4. timeline → ntsb 已注册
5. chat-stream → buyer-center 上游
6. recommendation-config → 同组参考

**第二波（Java Maven，无 DB 或简单 PG）**：
1. policy-tools → sonar-java
2. common-libs → 基础库
3. assistant → build.sh
4. store-home → peroration 参考

**第三波（其他语言/框架）**：
1. business-rule → Python + Airflow
2. citi → Python ML
3. oppo-v2 → 待确认
