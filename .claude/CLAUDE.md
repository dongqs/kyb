# CLAUDE.md — orb

OrbStack AI 开发沙箱配置仓库。用 Docker 容器提供隔离的开发环境，替代之前的 OrbStack Machine 方案。

## 关键文件

- `Dockerfile` — 定义沙箱镜像（Ubuntu 24.04 + mise + Node + Claude Code）
- `entrypoint.sh` — 容器启动时调整 UID/GID 匹配宿主机用户
- `bin/create-sandbox` — 主脚本：构建镜像 → 启动容器 → clone 项目
- `bin/enter-sandbox` — 进入容器 shell
- `projects.txt` — 要 clone 的项目 URL 列表，# 开头为注释

## 常用操作

- 创建/重建沙箱: `~/orb/bin/create-sandbox`
- 进入沙箱: `~/orb/bin/enter-sandbox`
- 手动进入: `docker exec -it -u dev -w /home/dev dev-sandbox bash`
- root 执行: `docker exec -u root dev-sandbox <cmd>`
- 停止沙箱: `docker stop dev-sandbox`
- 删除沙箱: `docker rm -f dev-sandbox`
- 查看状态: `docker ps -a --filter name=dev-sandbox`

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `~/orb/bin/create-sandbox` 重建

## 添加新项目

1. 编辑 `projects.txt`，加一行 git clone URL
2. 重建沙箱，或手动 `docker exec` 进入 `git clone`

## 沙箱环境

- **PostgreSQL 16** — 随容器启动，trust 认证，时区 Asia/Shanghai
- **mig25** — 从 Nexus 安装，DSN 配在项目 `.env` 里
- **Node LTS** — 通过 mise 管理
- **Claude Code** — npm 全局安装

## Norland / mig25 项目

`projects/Norland/` 是 PostgreSQL schema-only 项目（乐言电商订单/店铺表结构）。

```bash
# 进入沙箱
~/orb/bin/enter-sandbox

# 初始化（首次）
cd ~/projects/Norland
echo 'MIG25_DSN=postgresql://postgres:postgres@127.0.0.1:5432/postgres' > .env
echo y | mig25 init

# 日常操作
mig25 list        # 查看 migration 状态
mig25 upgrade     # 执行待应用的 migration
mig25 boomerang   # 完整 CI 验证：建库 → 全量 migration → 测试 → 拆库
```

mig25 要求 PG 时区为 Asia/Shanghai，已在 Dockerfile 中预设。

## 宿主机挂载

- `~/.ssh` → 容器内 `/home/dev/.ssh` (只读)
- `~/.gitconfig` → 容器内 `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → 容器内 `/home/dev/.claude/settings.json` (只读)
- `~/projects` → 容器内 `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问

## 为什么用 Docker 而不是 Machine

Machine 方案需要 cloud-init 管理用户创建、文件编码、chown 时机、systemd 等，迭代了 8 个 commit 才稳定。Docker 容器用 entrypoint + volume 挂载天然解决了这些问题，且更轻量。
