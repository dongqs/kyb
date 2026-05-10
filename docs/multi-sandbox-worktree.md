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
| `symlinks` | 否 | 需要从主工作树符号链接到 worktree 的目录/文件 |
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
6. 对于每个 symlinks: ln -sf <主工作树>/<target> <worktree>/<target>
7. env_template 存在 → cp <主工作树>/<env_template> <worktree>/.env
8. docker rm -f dev-niao-3333   # 如果已有容器
9. docker run -d
     - name: dev-niao-3333
     - -p 3333:3000
     - -v ~/.orb/worktrees/niao/dev-niao-3333:/home/dev/projects/niao
     - -v niao-node_modules:/home/dev/projects/niao/node_modules
     - ...（ssh、gitconfig、docker.sock 等保持不变）
```

## 容器内 entrypoint.sh

- `cd ~/projects/niao && mise trust`（如项目使用 mise）
- `npm install`（node_modules volume 首次为空时安装）

## 资源隔离

- **项目代码** — 各自 worktree，互不干扰
- **node_modules** — per-project 共享 volume（`<project>-node_modules`）
- **容器名** — `dev-<project>` 或 `dev-<project>-<port>`
- **分支名** — `sandbox/<project>` 或 `sandbox/<project>-<port>`

## 清理

手动管理。后续补充 `bin/clean-sandbox` 脚本。

- `docker rm -f dev-niao-3333` → 删容器
- `git worktree remove ~/.orb/worktrees/niao/dev-niao-3333` → 删 worktree
- `git branch -D sandbox/niao-3333` → 删分支
