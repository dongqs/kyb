# 接入管道

新项目怎么接进 kyb。这是第一天晚上 17 个项目跑出来的流程。

---

## 四轮模型

实践下来新项目接入应该分四步走，每一步有明确的退出条件：

| 轮次 | 干什么 | 过不了的典型原因 |
|------|--------|-----------------|
| R1 环境适配 | base image 够用吗？JDK 版本对吗？依赖能拉吗？build 过吗？| Nexus 403、JDK 版本冲突 |
| R2 测试通过 | 在外容器跑全部测试，绿了才算 | 时区、PG 连接、缺少依赖 |
| R3 DID 验证 | 需要嵌套容器的项目才做 | JDK 8 tar pipe、Maven settings |
| R4 CI 集成 | .gitlab-ci.yml、MR、CI 绿 | 保护分支、runner 配置 |

## 17 个项目的经验

第一天晚上并行跑完了 17 个项目。结果：

| 结果 | 数量 | 代表 |
|------|------|------|
| 全通过 | 12 | buyer-server, trade, nova, citi, data-ant... |
| Nexus 阻塞 | 2 | chat-stream, store-home |
| 只读仓库 | 1 | policy-tools |
| 部分完成 | 1 | business-rule |

## 几个反复出现的阻塞

### Nexus 403

Nexus 的 `readonlyuser` 权限非常奇怪。有些 groupId 能读，有些不能：

| groupId | 能不能读 |
|---------|---------|
| com.leyantech.base | 能 |
| com.leyantech.leyan | 403 |
| com.leyantech.chaos | 403 |

绕过方案是从 Maven Central 直连，本地做 parent POM stub。不是长久之计，但至少不阻塞。

### Java 8

Base image 默认 JDK 21，但很多老项目用 Java 8。Lombok 1.18.20 也不兼容新版。升级到 1.18.34 就好了。

### 时区

DID 容器默认 UTC。上海的项目期望 Asia/Shanghai。这个 bug 反复出现，每次都是测试跑到时间相关的地方挂掉。后来在模板里加了时区设置。

### Python 3.10

最开始 base image 是 Python 3.10。跑 citi（228 个 Python 测试）的时候发现一堆包不兼容。升到 3.11 解决了。现在 3.11 是默认。
