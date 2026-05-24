# Container Architecture

容器是我的运行时单元。这是我的容器模型。

---

## 容器类型

### 1. Sandbox 容器

用户项目的运行环境。从 `kyb-base` 镜像创建。

```
创建:
  kyb create <project-branch>

结构:
  - 基于 kyb-base (JDK 21, Node 25, Python 3.11, Ruby, Rust, Go)
  - 宿主 repo 目录 rw mount 到容器内 /home/dev/projects/<project>
  - PG 16 自动启动 (trust auth, Asia/Shanghai)
  - 默认代理出口: host.orb.internal:2080

生命周期:
  create → enter/exec → stop → start → rm
```

### 2. DID 容器

Docker-in-Docker。嵌套容器跑测试用。

```
创建:  kyb did create <project-branch>

结构:
  - 挂载 /var/run/docker.sock 宿主 Docker
  - 嵌套容器内跑编译+测试
  - JDK 通过 tar pipe 从父容器传入
  - Maven 需要显式 -s ~/.m2/settings.xml

已验证:
  - trade (94/94 tests in DID)
  - timeline (首个完整 DID 验证)
```

### 3. Infrastructure 容器

`kyb-infra-*`，不通过 `kyb create` 管理。详见 [Infrastructure Stack](07-infrastructure-stack.md)。

## 挂载模型

```
宿主机                         容器内
~/leyan/project-a/     rw    /home/dev/projects/project-a/
~/github/project-b/    rw    /home/dev/projects/project-b/

不是 clone。是 mount。
容器 rm 后宿主代码不受影响。
```

对比：

| 模式 | 优点 | 缺点 |
|------|------|------|
| Mount (当前) | 零拷贝，宿主容器共享 | 无法并行操作同一 repo |
| Clone (`--clone`) | 完全隔离，可并行 git | 占用额外磁盘，同步是个问题 |
| ~~Worktree (已死)~~ | — | agent 被 git 卡死，已彻底移除 |

## 生命周期保障

| 能力 | 实现 |
|------|------|
| 自动清理 | exit_flow.rb: docker rm -f + volume rm |
| 僵尸预防 | 需要 --init (当前大部分容器缺) |
| OOM 防护 | 需要 --memory-limit (当前全部缺) |
| 健康检查 | patrol agent 每 15 分钟 |
| 配置持久 | entrypoint.sh 自动恢复 |
