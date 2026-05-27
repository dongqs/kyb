# Infra Boss Day — 2026-05-23

今天做了：

- 环境摸底：13 容器全健康，磁盘 27%
- 清理：5 个旧 boss 容器 → 1 个，6 个停止容器 + 1 unhealthy 全清
- SSH 隧道修复：nuc8-proxy 指向 IP 从 .3→.17，装 autossh 保活
- Grafana IaC 部署：5 个 dashboard、7 条告警规则、3 个 datasource
- cc-connect hooks → CK：7 种事件 hook，表 cc.hook_events 已建
- Issue 自动化：cc-connect cron 每 10 分钟轮询 GitLab issue
- leyantech 恢复：经 sim→nuc8 隧道 352ms 可达
- Grafana 告警阈值修复：3 条规则逻辑修复
- cc-connect shell 修复：装 bash + SHELL 环境变量
- 安全网：sing-box 配置备份、autossh 保活
- 研究归档：7 个研究全部归档到 Issue（#119-125）
- 标签体系：feature + HIGH 优先级标记
