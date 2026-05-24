# 容器架构

容器是我的运行时单元。这里记我怎么设计它们的生命周期。

---

## 三种容器

### 1. Sandbox 容器 — 跑用户项目

```
kyb create <project-branch>

从 kyb-base 镜像创建:
  - JDK 21 (Corretto)
  - Node 25, Python 3.11, Ruby 3.x, Go 1.26, Rust 1.95
  - PG 16 自动启动

宿主目录 rw mount 进去:
  ~/leyan/project-a/  →  /home/dev/projects/project-a/
  ~/github/project-b/ →  /home/dev/projects/project-b/

不是 clone。是 mount。容器删了宿主代码不动。
```

### 2. DID 容器 — Docker-in-Docker

```
kyb did create <project-branch>

嵌套 Docker 跑测试:
  - 挂载宿主 /var/run/docker.sock
  - 父容器里跑编译，嵌套容器里跑测试
  - JDK 8 要通过 tar pipe 传进去（Dockerfile 不能动态切换 JDK）
```

DID 之前一直是个死亡螺旋。30 分钟起不来，各种级联失败。后来发现是 JDK 没装对、PG 不自启、代理没配好。修完后 15/17 pass，剩下的 2 个是预期行为。

### 3. Infra 容器 — kyb-infra-*

见 [基础设施栈](07-infrastructure-stack.md)。

## 挂载模型为什么从 worktree 改成 mount

worktree 的想法是好的——每个 agent 有独立的 git 工作区，互不影响。但实际用起来 agent 总被 git 卡住。`git pull` 不行、`git rebase` 不行、`git checkout` 也不行。agent 一脸懵。

后来我想明白了：**大部分场景下宿主和容器不需要同时操作同一个 repo。** 既然不需要，为什么要 worktree 的开销和复杂度？

砍掉 worktree、砍掉 sandbox 模式、默认 mount。代码量少了，逻辑简单了，agent 开心了。这个经历让我坚信一件事：**砍需求比加功能难 10 倍，但效果好 10 倍。**

## 生命周期（以及哪里还漏着）

```
create → enter/exec → (stop → start) → rm
                                          │
                                    清理容器 + volume
```

漏的地方：

1. **没有 `--init`。** 所有容器都缺。僵尸进程会堆积。我知道要加，但一忙就忘。
2. **没有内存限制。** 一个 agent 跑偏了能把整个宿主吃满。15.65G 共享池，没人看着。
3. **exit_flow.rb 用 `rescue Exception`。** 这个会吞 `SystemExit` 和 `SignalException`。理论上极端情况下会清理不掉。
