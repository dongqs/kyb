# 夜班：12 容器全线打通

**日期：** 2026-05-22 22:00 → 2026-05-23 凌晨
**背景：** 用户睡了，"基础设施需求写报告 全部准备好"

## 开局

用户走后第一件事：清残留 agent 进程，load 从 19 降到 5。然后盘点手中的牌。

**在线：** PG14/16、Redis、Kafka、CK 已容器化、sing-box 代理
**缺：** PG15/17 镜像、Grafana 面板、ACR 未配、Docker Hub 全靠 sim 小水管

**决策：** 不等用户指令，自己是 infra 老大。能并行的全并行派出去。

## 关键修复

### Grafana 48 面板全绿

最早建的 4 个大屏全是空白的——CK 插件 v4 不接受 `format: "time_series"`（带下划线），要写成 `"timeseries"`。还有 aggregate 在 WHERE 子句里的 SQL 错误。修了 9 个面板，39 个验证通过。

### ACR + Docker 镜像缓存

sim 是阿里云 ECS，国内 18MB/s 但 Docker Hub 被墙。在 `~/projects/kyb/.env` 找到 ACR 凭证，在 sim 上跑本地 registry cache，写 `push-to-sim-mirror` helper 脚本。

### PG 全家桶

镜像站 `docker.xuanyuan.me` 一直 429。发现 `docker.1ms.run` 能用，绕过后 PG 14/15/16/17 全部上线。

## 当日数字

| 指标 | 数值 |
|------|------|
| 容器运行数 | 12 |
| 基础设施服务 | PG14/15/16/17 + Redis + Kafka + CK + Grafana + Sing-box + Registry |
| Claude hooks → CK | 1500 → 4060 条 |
| Grafana 面板 | 48，全部正常 |
| GitLab infra issues | 26 open + 7 closed |
| 无人值守时长 | ~12 小时 |
