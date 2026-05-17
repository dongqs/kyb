# kyb did 命名统一与软隔离设计

## 背景

kyb DID 容器命名混乱，与文档不一致，导致 `docker cp`/`docker exec` 无法定位目的容器。
核心问题：命名规则未统一、容器外按 name filter 和 label filter 两套体系混用、嵌套无约束。

## 容器命名

| 实体 | 格式 | 例子 |
|------|------|------|
| DID 容器 | `did-<project>-<branch>-<name>` | `did-kyb-niao-ios-dep` |
| DID volume | `did-<project>-<branch>-<name>-worktree` | `did-kyb-niao-ios-dep-worktree` |

`<name>` 为用户 `kyb did create <name>` 输入之短名。`<project>` 和 `<branch>` 从当前容器的 `KYB_PROJECT` + `KYB_BRANCH` 推导。

## 环境变量

### kyb 容器（`kyb create`）

| 变量 | 值 | 来源 |
|------|-----|------|
| `KYB_PROJECT` | 项目名 | 已有 |
| `KYB_BRANCH` | 分支名 | 新增，`docker.rb#run` 注入 |

### DID 容器（`kyb did create`）

| 变量 | 值 | 说明 |
|------|-----|------|
| `KYB_PROJECT` | `<name>`（用户输入的短名） | 已有，用于项目目录路径 |
| `KYB_BRANCH` | 从父容器传入 | 保持信息链 |
| `KYB_PARENT` | 父容器全名 | 已有，如 `kyb-kyb-niao-ios` |
| `KYB_DID` | `<name>`（用户输入的短名） | 新增，标记此容器为 DID 子容器 |

### Docker Labels

只保留一个：

| Label | 值 | 用途 |
|-------|-----|------|
| `did_parent` | 父容器全名 | CLI filter、级联清理 |

移除以太 label：`kyb-did`（原格式 `kyb-did=<parent>` 语义模糊，拆分后废弃）。

## 行为约束

### 嵌套拦截

DID 容器内 `KYB_DID` 已设，执行 `kyb did create` → 报错退出，禁止二级嵌套。

### 冲突检测

`kyb did create` 时全局查所有 Docker 容器名（不限 `did-*` 前缀），冲突则报错提示。

## 软隔离（`kyb did ps`）

| 位置 | `kyb did ps`（默认） | `kyb did ps --all` |
|------|-------------------|-------------------|
| 宿主机 | 所有 `did-*` | 所有 `did-*` |
| 普通容器内 | 只显示 `did_parent=<self>` 的 sibling | 所有 `did-*` |
| DID 容器内 | 只显示 `did_parent=<parent>` 的 sibling | 所有 `did-*` |

## 级联清理

`kyb rm <project>-<branch>`、`kyb prune` 中：

```
docker ps -a --format '{{.Names}}' --filter label=did_parent=<self>
```

替代原有：

```
docker ps -a --format '{{.Names}}' --filter label=kyb-did=<self>
```

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `lib/kyb/docker.rb` | `run()` 中加 `-e "KYB_BRANCH=#{branch}"` |
| `lib/kyb/cli/did.rb` | 全局重写：命名格式、env、label、嵌套检测、冲突检测、`did_ps` 软隔离 |
| `lib/kyb/cli/manage.rb` | `rm`/`prune` 中 `kyb-did` → `did_parent` |
| `lib/kyb/container.rb` | 无需改动（DID 不使用 Container class） |
| `docs/kyb-did.md` | 同步更新容器规范、命令说明、清理流程 |
