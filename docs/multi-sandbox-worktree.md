# 多实例 Sandbox — Worktree 隔离方案

## 问题

`create-sandbox niao` / `create-sandbox niao 3333` 同时开多个容器，都挂载同一个宿主机项目目录，互相干扰。

## 方案

每个容器创建独立的 git worktree，挂在宿主机 `~/.orb/worktrees/<project>/<container>/`，Docker 挂载各自 worktree 而非主工作树。

## projects.toml 配置

```toml
[projects.niao]
path = "~/github/niao"
base_branch = "master"
ports = ["3000:3000"]
symlinks = ["tiles"]
env_template = ".env.sample"

[projects.hamilton]
path = "~/leyan/training/hamilton"
base_branch = "main"
ports = []
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `path` | 是 | 宿主机项目主工作树路径 |
| `base_branch` | 是 | 从哪个分支切 worktree |
| `ports` | 否 | 容器端口映射 |
| `dockerfile` | 否 | 项目级 Dockerfile（相对 path），用于构建项目特定镜像 |
| `symlinks` | 否 | 从主工作树只读挂载到容器的目录/文件（Docker bind mount） |
| `env_template` | 否 | 复制到 worktree 的 .env 模板文件 |

## create-sandbox 流程

```
create-sandbox niao 3333

1. docker build base image（如有变更）
2. 解析 projects.toml，获取项目配置
3. cd <主工作树路径>
4. git fetch origin <base_branch>
5. git worktree add ~/.orb/worktrees/niao/dev-niao-3333 origin/<base_branch>
   分支名: sandbox/niao-3333
   已存在则跳过，复用
6. 对于每个 symlinks: Docker bind mount <主工作树>/<target> → 容器内 <项目>/<target> (只读)
7. env_template 存在 → cp <主工作树>/<env_template> <worktree>/.env
8. docker rm -f dev-niao-3333   # 如果已有容器
9. docker run -d
     - name: dev-niao-3333
     - -p 3333:3000
     - -v ~/.orb/worktrees/niao/dev-niao-3333:/home/dev/projects/niao
     - -v ~/github/niao:/home/dev/projects/niao/tiles:ro   # symlinks 每个单独挂载
     - -v ~/github/niao:~/github/niao   # 主工作树，保证容器内 git worktree 操作正常
     - -v niao-node_modules:/home/dev/projects/niao/node_modules
     - -v dev-niao-3333-claude:/home/dev/.claude   # 每个容器独立的 Claude 配置
     - ...（ssh、gitconfig、docker.sock 等保持不变）
```

## 容器内 entrypoint.sh

- `cd ~/projects/niao && mise trust`（如项目使用 mise）
- `eval "$(mise activate bash)"`（确保工具链可用）
- `npm install`（node_modules 为空时安装）

## 资源隔离

- **项目代码** — 各自 worktree，互不干扰
- **node_modules** — per-project 共享 volume（`<project>-node_modules`）
- **Claude 配置** — per-container volume（`<container>-claude`），互不干扰
- **主工作树** — 只读 bind mount 到容器内同路径，供 `git fetch` 等操作使用
- **容器名** — `dev-<project>` 或 `dev-<project>-<port>`
- **分支名** — `sandbox/<project>` 或 `sandbox/<project>-<port>`

## 分支收尾（teardown）

当一个 sandbox 实例不再需要时，完整收尾流程如下。

### 正常收尾（容器和 worktree 都还在）

```bash
# 1. 删容器
docker rm -f dev-niao-3333

# 2. 删 worktree（同时删除本地分支）
git -C ~/github/niao worktree remove ~/.orb/worktrees/niao/dev-niao-3333

# 3. 删远程分支
git -C ~/github/niao push origin --delete sandbox/niao-3333

# 4. 清理已不存在的 worktree 记录（可选）
git -C ~/github/niao worktree prune
```

注意：`git worktree remove` 会自动删除关联的本地分支，不需要单独 `git branch -D`。

### 异常收尾（容器/worktree 已丢失）

当容器被删但 worktree 目录还在（或反之），或者像裸删 Docker 容器后 worktree 和分支残留在 git 中：

```bash
# 查看当前 worktree 状态
git -C ~/github/niao worktree list

# 如果有残留的 worktree 目录但 git 已不追踪，直接删目录
rm -rf ~/.orb/worktrees/niao/dev-niao-4444

# 删本地分支（-d 已合并，-D 强制）
git -C ~/github/niao branch -d sandbox/niao-4444   # 优先
git -C ~/github/niao branch -D sandbox/niao-4444   # 不检查合并

# 删远程分支
git -C ~/github/niao push origin --delete sandbox/niao-4444

# 清理无效 worktree 记录
git -C ~/github/niao worktree prune

# 清理对应的 Docker 匿名 volume（如需要）
docker volume rm niao-node_modules dev-niao-4444-claude
```

### 快速诊断

```bash
# 列出所有分支，+ 号标记的表示有活跃 worktree
git -C ~/github/niao branch
#   adjust-color
#   adjust-disp
# * master
# + sandbox/niao-3333    ← 有 worktree
#   sandbox/niao-4444    ← 无 worktree，可清理

# 查看 worktree 详情
git -C ~/github/niao worktree list

# 查看哪些容器在跑
docker ps -a --filter name=dev-
```

### 批量收尾脚本

```bash
# 清理所有 dev-niao-* 容器
docker ps -aq --filter name=dev-niao- | xargs -r docker rm -f

# 清理所有 niao worktree 目录
ls -d ~/.orb/worktrees/niao/dev-niao-* 2>/dev/null | xargs -r rm -rf

# 清理所有无 worktree 的 sandbox 分支
git -C ~/github/niao branch | grep 'sandbox/' | while read b; do
    # 跳过带 + 的分支（有活跃 worktree）
    [[ "$b" == +* ]] && continue
    b="${b#  }"
    echo "  delete $b"
    git -C ~/github/niao branch -D "$b"
    git -C ~/github/niao push origin --delete "$b" 2>/dev/null || true
done

# 清理无效 worktree 记录
git -C ~/github/niao worktree prune
```
