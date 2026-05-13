# CLAUDE.md

AI 开发沙箱配置仓库。用 Docker 容器提供隔离的开发环境。

## 关键文件

- `Dockerfile` — 沙箱镜像定义
- `entrypoint.sh` — 容器启动入口
- `bin/kyb` — CLI 工具
- `~/.config/kyb/config.yml` — 用户级项目配置

## 常用操作

- `kyb build` — 构建基础镜像
- `kyb create <name>` — 创建并启动沙箱
- `kyb enter <name>` — 进入沙箱
- `kyb ps` — 列出沙箱
- `kyb stop <name>` — 停止沙箱
- `kyb rm <name>` — 删除沙箱
- `kyb prune` — 删除所有沙箱

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`：

```yaml
projects:
  my-project:
    path: "~/path/to/project"
    base_branch: master
    ports:                    # 可选
    - 3000:3000
    symlinks:                 # 可选
    - shared/vendor
    mounts_rw:                # 可选
    - /host/path:/container/path
    mounts_ro:                # 可选
    - /host/path:/container/path
```

## 沙箱环境

- **PostgreSQL 16** — trust 认证，Asia/Shanghai
- **mig25** — DSN 配在项目 `.env`
- **Node LTS** — mise 管理
- **Claude Code** — npm 全局安装

## 宿主机挂载

- `~/.ssh` → `/home/dev/.ssh` (只读)
- `~/.gitconfig` → `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → `/home/dev/.claude-host-settings.json` (只读)
- `~/.claude/skills` → `/home/dev/.claude-skills-host` (只读)
- `~/projects` → `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问
- `mounts_rw` / `mounts_ro` → 项目级外部目录挂载
