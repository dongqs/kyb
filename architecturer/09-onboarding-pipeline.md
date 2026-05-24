# Onboarding Pipeline

项目怎么接入我。17 个项目一晚上验证过的流程。

---

## 四轮模型

```
Round 1: 环境适配 (不跑测试)
  ├── Base image 够用吗
  ├── JDK 版本匹配 (21 vs 8)
  ├── 依赖能拉吗 (Nexus/Maven Central)
  ├── Build 能过吗
  └── 输出: .kyb.md + Dockerfile (如需要)

Round 2: 测试通过 (外容器)
  ├── 所有测试在 sandbox 中能跑
  ├── PG/Redis 等依赖就绪
  └── 输出: 测试全绿

Round 3: DID 验证 (如果项目需要)
  ├── 嵌套容器内编译+测试
  ├── JDK/Maven tar pipe
  └── 输出: DID 测试全绿

Round 4: CI 集成
  ├── .gitlab-ci.yml 配置
  ├── 特殊构建步骤
  └── 输出: MR created + CI pass
```

## 17 项目结果

| 结果 | 数量 |
|------|------|
| 全 4 轮收敛 + MR | 12 |
| Nexus 阻塞 | 2 (chat-stream, store-home) |
| 只读仓库阻塞 | 1 (policy-tools) |
| 部分完成 | 1 (business-rule) |

## 阻塞模式

### Nexus 403

`readonlyuser` 的权限边界：

| groupId | 状态 |
|---------|------|
| `com.leyantech.base` | 🟢 可读 |
| `com.leyantech.leyan` | 🔴 403 |
| `com.leyantech.chaos` | 🔴 403 |

绕过方案：Maven Central 直连 + 本地 parent POM stub。

### Java 8 项目

JDK 21 是 base image 默认。Java 8 项目需手动切换。Lombok 1.18.20 不兼容新版本，需升级到 1.18.34。

### 时区

DID 容器默认 UTC，上海项目期望 Asia/Shanghai。反复出现的测试杀手。

## Python 支持

当前 base image Python 3.11（从 3.10 升级）。历史问题：

- grpcio 1.43 在 arm64 上损坏 → 需升级
- librdkafka-dev 缺失 → apt-get 补装
- protobuf 版本冲突 → 约束版本

## 工具链版本

| 工具 | 版本 | 备注 |
|------|------|------|
| JDK | 21 (Corretto) | + 8/11/17 可选 |
| Node | 25 | mise 管理 |
| Python | 3.11 | 从 3.10 升级 |
| Ruby | 3.x | stdlib only |
| Go | 1.26 | 新增 |
| Rust | 1.95 | 新增 |
