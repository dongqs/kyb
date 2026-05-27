# 2026-05-27 — 架构 journey 03：夜班 12 容器

原始文件：`architecturer/journey/03-night-watch.md` — 2026-05-22 晚 → 23 凌晨

**用户去睡了，留 12 个容器全要一个人看。**

开局清场：残留 agent 进程 load 19 → 清到 5。盘完库存（PG14/16/Redis/Kafka/CK/sing-box 在线）→ 不等指令直接干。

**Grafana 48 面板：** 从 4 个空白到 48 个全绿。踩坑：CK 插件 v4 不接受 `format:"time_series"`（要 `"timeseries"`）。

**ACR + 镜像缓存：** sim（阿里云 ECS）Docker Hub 被墙 → 找 ACR 凭据 → 搭本地 registry cache。

**PG 四世同堂：** docker.xuanyuan.me 429 → 发现 docker.1ms.run 能用 → PG 14/15/16/17 全部上线。

**凌晨三点顿悟：** Grafana 活动曲线是平的（用户在睡觉），4000 条 events 躺 CK 里。系统真的自己跑起来了。

**40 多轮巡检零异常。** 天亮用户第一句话："坏了" —— 不是夜班的问题。
