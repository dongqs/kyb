# Java 预装到基础镜像

## 背景

commit `0160061` 从基础镜像移除了 Java，让项目通过 mise 自行安装。实测结果：

| 场景 | 耗时 | 问题 |
|------|------|------|
| buyer-server（mise cache 热） | ~15s | 可接受 |
| nova（mise cache 冷） | ~2m07s | 慢 |
| data-ant（mise cache 冷） | ~2m30s | 很慢 |

所有 Java 项目（buyer-server、nova、data-ant 都是 Java 21）首次冷启动都需要 ~2min+ 下载 GraalVM，这对"秒级拉起"的目标不可接受。

## 方案

### 方案 A：加回 mise.config.toml

```toml
[tools]
java = "graalvm-community-21"
```

**优点**：一行配置，mise install 自动装好。
**缺点**：改动 mise.config.toml 会断后续所有层的 Docker cache（见 `docs/build/docker-cache-optimization.md`）。
如果和 Docker cache 分层优化（方案 A）一起做，把 Java 放进"稳定层"，则改动不影响其他工具。

### 方案 B：Dockerfile 单独 RUN

```dockerfile
RUN eval "$($HOME/.local/bin/mise activate bash)" && \
    mise install java@graalvm-community-21 && \
    mise use -g java@graalvm-community-21
```

**优点**：Java 版本变化不影响 mise.config.toml 的 cache。
**缺点**：多一层。

### 方案 C：entrypoint 延迟安装

entrypoint 检测 `java` 不存在时自动 `mise install java`。

**优点**：镜像不受影响，按需安装。
**缺点**：首次容器启动慢 2min+，不能接受。

## 建议

**方案 A + Docker cache 分层**。把 Java 和 node/python/ruby 一起放在稳定层，maven/glab等放变动层。
这样 Java 版本几乎不变，cache 很少失效。

## 待办

- [ ] Docker cache 分层改造
- [ ] Java 加入 mise 稳定配置
- [ ] 重新 build 并验证三项目冷启动耗时
