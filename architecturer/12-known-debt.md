# Known Debt

我身上还有没修的事。诚实面对。

---

## 架构债务

| # | 债务 | 影响 | 优先级 |
|---|------|------|--------|
| 1 | `Docker.run` 115 行超大方法 | 修改成本高，混了太多职责 | Medium |
| 2 | `Docker.create_container` 110+ 行 | 同上 | Medium |
| 3 | `rescue Exception` / `rescue nil` 滥用 | 吞掉 SystemExit/SignalException | Medium |
| 4 | 三处重复模式 (volume/DID/轮询) | 熵的主要来源 | Medium |
| 5 | 测试污染 (define_singleton_method) | CI 不稳定 | High (已修 3/5) |
| 6 | Config `save` 非原子 | 并发写可损坏配置 | Low |
| 7 | 30% 测试在 CI 跳过 | 回归覆盖不足 | Medium |

## 基础设施债务

| # | 债务 | 影响 | 优先级 |
|---|------|------|--------|
| 1 | 所有容器缺 `--init` | 僵尸进程堆积 | **High** |
| 2 | 所有容器无内存限制 | OOM 炸穿宿主 | **High** |
| 3 | 所有容器缺 `NO_PROXY` | 全部流量走代理的性能损失 | Low |
| 4 | entrypoint 无自动修 sing-box 配置 | 重建后 .17→.3 需手动 | Medium |
| 5 | API Key 通过 `-e` 传环境变量 | `ps aux` 可见凭据 | Medium |
| 6 | 无容器创建限流 | 潜在滥用 | Low |
| 7 | Nexus 部分 groupId 403 未解决 | onboarding 阻塞 | Medium |
| 8 | Python grpcio arm64 损坏 | arm64 兼容性税 | Low |

## 流程债务

| # | 债务 | 说明 |
|---|------|------|
| 1 | 缺少输出模板 (JSON schema) | Agent 产出格式不统一，汇总费力 |
| 2 | 打标靠手工 | 138 份文件打标花 30 分钟，应半自动化 |
| 3 | 缺少自动摘要 pipeline | Boss 需要通读所有 agent 产出，认知负荷大 |
| 4 | 最长尾等待 | 复杂方向拖慢整体，应设超时或异步交付 |

## 已修 vs 待修

```
已消灭:
  8 项 (6 shell 注入 + 2 死常量 + 1 crash + 1 功能缺失 + 1 输入校验 + 14 孤儿卷 + 3 过期容器)

待修:
  ~87 项 (来自健壮性审计 95 项总发现)
```
