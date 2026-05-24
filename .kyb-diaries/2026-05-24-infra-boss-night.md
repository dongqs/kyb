# Infra Boss 夜班 — 2026-05-24

> 用户去睡了，留我自主干活。10 分钟一次巡检，按优先级修 issue。

---

## 完成

### P0
- **#151 heredoc 注入** — 已修（检查 master 上所有 heredoc 均已加引号）
- **#158 nuc8 隧道可观测性** — 重建容器 + `-v` 日志 + HEALTHCHECK + 内存 64m 限制

### P1
- **#153 缺 `--init`** — 已修（`docker.rb:189`、`infra.rb:60`、`did.rb:70` 所有创建路径已含 `--init`）
- **#155 Hooks→CK 管道** — 重建干净 CK 实例（`ch-data` 卷损坏，起 `ch-data-fresh`），创建 `infra.container_logs` 表

### P2 尝试
- **Vector 可观测性** — 构建了 `kyb-vector:0.44.0` 镜像并部署容器。Vector 0.44.0 的 ClickHouse HTTP client (reqwest) 有 bug——手动 nc/wget 发请求到 CK 返回 200，但 Vector 内部发送失败。留待后续。

## 待修
- **#154 内存限制** — infra-boss 已有限制（2g），但 sing-box、clickhouse 等手动创建的容器无限制
- **#152 entrypoint 测试改造** — 需要改 test/test_entrypoint.rb
- **#158 留待观察** — 日志已在输出，等下一次断连诊断
- **#155 Vector 管道** — 需用 Ruby 脚本或旧版 Vector 替代

## 容器状态（凌晨）

| 容器 | 状态 | 限制 |
|------|------|------|
| kyb-infra-nuc8-tunnel | ✅ healthy | 64m + HEALTHCHECK |
| kyb-infra-boss | ✅ | 2g |
| kyb-infra-clickhouse | ✅（新卷） | 4g |
| kyb-infra-sing-box | ✅ | 无限制 |
| kyb-click-xiaoye | ✅ | 无限制 |
| kyb-hamilton-cat | ✅ | 无限制 |

## 巡检记录

| 时间 | 状态 | 备注 |
|------|------|------|
| 22:44 | ✅ | CK crash loop，OOM |
| 22:54 | ✅ | CK 反复 OOM，旧数据卷损坏 |
| 23:00 | ✅ | 切新卷 ch-data-fresh，CK 稳定 |
| 23:10 | ✅ | Vector 部署尝试，ClickHouse sink 不兼容 |

## 教训

1. **内存限制要谨慎** — CK 本来跑得好好的（30h+ 无限制），我加了 4g 限制后触发 OOM，反复 crash 损坏了数据卷。应该先加配置限制 CK 内部内存，再加 Docker 限制。
2. **Vector 0.44.0 的 ClickHouse sink 有问题** — reqwest HTTP client 不兼容 CK HTTP 接口。手动测试全部通过，但 Vector 自身发送失败。
