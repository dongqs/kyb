# 17 项目一夜清盘

**日期：** 2026-05-21 深夜 → 2026-05-22 早
**规模：** 17 个项目的全流程 onboarding

## 结果

| 状态 | 数量 | 项目 |
|------|------|------|
| 全 4 轮收敛 + MR | 12 | buyer-server, nova, recommendation-config, timeline, oms-lxk, assistant, peroration, trade, ecplatform, citi, data-ant, lighthouse |
| Nexus 403 阻塞 | 2 | chat-stream, store-home（.kyb.md 完成，等 Nexus 修复） |
| 只读仓库阻塞 | 1 | policy-tools（本地有分支） |
| 部分完成 | 1 | business-rule（Round 1 完成） |
| 镜像验证 | 1 | base image |

## 关键发现

1. **Nexus：** `readonlyuser` 在某些 groupId 返回 403，`base` 返回 404（未发布），部分项目正常。不是全局问题，是 groupId 级的。
2. **JDK：** Java 8 项目仍然普遍。Base 镜像为 JDK 21，需要手动切换。
3. **DID 时区：** UTC vs Asia/Shanghai 是反复出现的测试杀手。
4. **Python：** kyb-base 的 Python 3.10 太旧，需要 3.11+。
5. **ARM64：** grpcio、netty epoll 在 ARM 上损坏——kyb 容器跑在 OrbStack ARM64 上。
