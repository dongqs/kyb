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

## 宿主机挂载

- `~/.ssh` → 容器内 `/home/dev/.ssh` (只读)
- `~/.gitconfig` → 容器内 `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → 容器内 `/home/dev/.claude/settings.json` (只读)
- `~/projects` → 容器内 `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问

## 为什么用 Docker 而不是 Machine

Machine 方案需要 cloud-init 管理用户创建、文件编码、chown 时机、systemd 等，迭代了 8 个 commit 才稳定。Docker 容器用 entrypoint + volume 挂载天然解决了这些问题，且更轻量。
