# 15 路全面体检

**日期：** 2026-05-23
**结构：** 5 方向 × 3 人交叉验证

## 方向

| # | 方向 | 覆盖 |
|---|------|------|
| 1 | 容器 & 资源 | 容器清单、--init/内存、磁盘 |
| 2 | 核心服务 | PG 全家桶、Redis+Kafka、CK+Grafana |
| 3 | 网络 & 代理 | sing-box、代理链路、nuc8 隧道 |
| 4 | Boss & 孤儿 | boss 三兄弟对比、孤儿清查、cc-connect |
| 5 | 文档 & 配置 | registry-cache 真实性、配置审计、交接优先级 |

## 覆盖范围

- 20 个容器（16 运行 + 4 停止）
- 从容器层到配置层，垂直扫描

## 输出

三大红色警报（详见 [3-red-alerts](3-red-alerts.md)）和 Boss 重建方案（详见 [boss-rebirth](boss-rebirth.md)）。
