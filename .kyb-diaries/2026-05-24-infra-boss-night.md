# Infra Boss 夜班 — 2026-05-24

> 用户去睡了，留我自主干活。10 分钟一次巡检，按优先级修 issue。

---

## 完成

### P0
- **#151 heredoc 注入** — 已修（检查 master 上所有 heredoc 均已加引号）
- **#158 nuc8 隧道可观测性** — 重建容器 + `-v` 日志 + HEALTHCHECK + 内存 64m 限制

### P1
- **#153 缺 `--init`** — 已修（`docker.rb:189`、`infra.rb:60`、`did.rb:70` 所有创建路径已含 `--init`）

### 待修
- **#154 内存限制** — infra-boss 已有限制（2g），但 sing-box、clickhouse 等手动创建的容器无限制。需要重建这些容器。
- **#155 Hooks→CK 管道** — 需要 CK 端重建库和表
- **#152 entrypoint 测试改造** — 需要改 test/test_entrypoint.rb
- **#158 留待观察** — 日志已在输出，等下一次断连诊断

## 容器状态（凌晨）

```
kyb-infra-nuc8-tunnel    ✅ Up (HEALTHCHECK: starting)
kyb-infra-boss            ✅ Up (2g limit)
kyb-click-xiaoye          ✅ Up
kyb-hamilton-cat          ✅ Up
kyb-infra-sing-box        ✅ Up
kyb-infra-clickhouse      ✅ Up
```

## 巡检

每 10 分钟自动检查一次：一直无症状。

---

*下一轮：继续修 P1 #154（内存限制）→ #155（Hooks→CK）*
