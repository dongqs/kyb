# kyb-infra-boss 快速上手指南

> 写给新 boss。在你跑 `kyb preflight` 之前先看这个，里面有些「文档不会告诉你的活状态」。

---

## 1. Boss 三兄弟 — 别杀错人

当前有 3 个 boss 同名容器：

| 容器 | 状态 | --init | 内存 | 用来干嘛 |
|------|------|--------|------|---------|
| **kyb-infra-boss**（你） | 新拉的 | ✅ | 有限制 | **你就是这个** |
| kyb-infra-boss-fallback | 正常运行 | ❌ | 无限制 | 上一任 boss **改名**后退下来的，还活着，有当前会话 |
| kyb-infra-boss-old | 正常运行 | ❌ | 无限制 | **nuc8 SSH 隧道挂在这里** — 别动！ |
| kyb-infra-boss2 | 正常运行 | ✅ | 4GiB | 合规但完全空闲，可择机清理 |

**⚠️ 红线：`kyb-infra-boss-old` 不能删。** 它的 PID 1 里跑着 SSH 隧道：

```
boss-old:2081 → SSH → nuc8(100.98.29.39):2081
```

GitLab（git.leyantech.com）的流量走这条路。SSH 隧道经 Tailscale 直连 nuc8（不再经 sim 跳转），`entrypoint.sh` 已集成 autossh 保活。

## 2. Registry Cache — 文档写的全是错的

| 项目 | 文档写的 | **实际运行** |
|------|---------|------------|
| 容器名 | `kyb-infra-registry` | **`kyb-registry-cache`** |
| 网络 | `--network kyb-net` | **host 模式** |
| 端口 | 5000 / 5001 | **5002**（无 -p 映射） |
| 代理 | `ALL_PROXY=socks5://kyb-infra-sing-box:2080` | **HTTP_PROXY=http://192.168.97.2:2080** |

**根本跑不通。** 先修文档再动手。

## 3. Hooks → CK 管道是断的

交接文档说"6700+ events"，但那**是上一任 session 的历史数据**。当前真实状态：

- CK 里没有 `kyb` 数据库
- `/home/dev/.claude/hooks/emit-ck.sh` 不存在
- `~/.claude/settings.json` 没有 hooks 配置块

你这轮 session 的一条 event 都没进 CK。重建前查不到任何数据。

## 4. kyb-base 镜像没 tag

`kyb-base:latest` 现在是 dangling（无引用）。如果你崩了想 `docker run kyb-base`，会找不到镜像。

重建前确认 `docker images kyb-base` 有输出。如果 dangling，需要先 `kyb build`。

## 5. 分支上的未 commit 文档

当前分支 `kyb/fix-infra-docs` 有 5 个 untracked 文件等你处理：

```
docs/infra/multi-cluster-boss-architecture.md  # 多集群架构设计
docs/infra/chat.md                             # IM 排障手册
docs/infra/handbook/hooks-ck-pipeline.md       # CK pipeline handbook
docs/infra/handbook/registry-cache-deploy.md   # registry 文档（内容全错，见上）
.kyb-diaries/2026-05-22-23-infra-day-two.md    # 日记
```

## 6. 明文 API Token

`ANTHROPIC_AUTH_TOKEN` 明文写在 `~/.claude/settings.json` 和 `~/.claude-host-settings.json` 里。上轮已知但没修。

## 7. Go 工具不认 ALL_PROXY

Go 程序（`glab` 等）只用 `HTTPS_PROXY`，不读 `ALL_PROXY`。环境变量里 `HTTPS_PROXY` 是空的。

```bash
# 正确用法：
HTTPS_PROXY=socks5://host.docker.internal:2080 glab ...
```

## 8. 存储可回收但不建议直接 prune

Docker 有 ~37GB 可回收，但：
- `kyb-kyb-robust-claude` 等 6 个 dangling 卷是上个 session 的 Claude 状态，删了不可逆
- 共享 cache volumes（gradle/maven/mise/pip/node_modules/swift）**被多个容器共用**，别删
- 真要清理：先列清谁在用，再动手

---

## 快速验证清单（优先级排序）

```
□ 1. 自己叫啥：hostname               # 应该是 kyb-infra-boss
□ 2. 隧道活着：ALL_PROXY=socks5://host.docker.internal:2080 curl -sI https://git.leyantech.com
□ 3. 代理正常：ALL_PROXY=socks5://host.docker.internal:2080 curl -sI https://github.com
□ 4. 镜像存在：docker images kyb-base
□ 5. CK 活着：curl -s http://host.orb.internal:8123/?query=SELECT+1
□ 6. PG 在线：docker exec kyb-infra-postgresql-16 pg_isready -U postgres
□ 7. 磁盘健康：df -h / | tail -1
□ 8. 没 zombie：ps -eo stat | grep -c Z
□ 9. 哪些容器没 --init：docker inspect $(docker ps -q) --format '{{.Name}} Init={{.HostConfig.Init}}'
```

---

> 如果需要迁走 nuc8 隧道再清 boss-old，流程是：
> 1. 新 boss 重建后 `entrypoint.sh` 已自动建立新隧道（autossh + Tailscale 直连 nuc8，无需 sim）
> 2. 确认新隧道 GitLab 通：`docker exec kyb-infra-boss curl -sx socks5://127.0.0.1:2081 https://git.leyantech.com`
> 3. 再停 boss-old 里的旧隧道进程
> 4. 确认 GitLab 仍然通

／人◕ ‿‿ ◕人＼
