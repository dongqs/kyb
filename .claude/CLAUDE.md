# CLAUDE.md — kyb ／(◕‿‿◕)＼

AI 开发沙箱配置仓库。用 Docker 容器提供隔离的开发环境，替代之前的 OrbStack Machine 方案。

## 关键文件

- `Dockerfile` — 定义沙箱镜像（Ubuntu 24.04 + mise + Node + Claude Code）
- `entrypoint.sh` — 容器启动时调整 UID/GID 匹配宿主机用户
- `bin/kyb` — CLI 工具：build / create / enter / exec / stop / start / rm / prune
- `~/.config/kyb/config.yml` — 用户级项目配置

## 常用操作

- 创建沙箱: `kyb create niao`
- 进入沙箱: `kyb enter niao`
- 列出沙箱: `kyb ps`
- 停止沙箱: `kyb stop niao`
- 删除沙箱: `kyb rm niao`
- 手动进入: `docker exec -it -u dev -w /home/dev kyb-niao-sandbox bash`
- root 执行: `docker exec -u root kyb-niao-sandbox <cmd>`

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`，添加项目配置，然后 `kyb create <name>`。

## 沙箱环境

- **PostgreSQL 16** — 随容器启动，trust 认证，时区 Asia/Shanghai
- **mig25** — 从 Nexus 安装，DSN 配在项目 `.env` 里
- **Node LTS** — 通过 mise 管理
- **Claude Code** — npm 全局安装

## Norland / mig25 项目

`projects/Norland/` 是 PostgreSQL schema-only 项目（乐言电商订单/店铺表结构）。

```bash
# 进入沙箱
kyb enter Norland

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
- `~/.claude/settings.json` → 容器内 `/home/dev/.claude-host-settings.json` (只读)
- `~/.claude/skills` → 容器内 `/home/dev/.claude-skills-host` (只读)
- `~/projects` → 容器内 `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问

## 为什么用 Docker 而不是 Machine

Machine 方案需要 cloud-init 管理用户创建、文件编码、chown 时机、systemd 等，迭代了 8 个 commit 才稳定。Docker 容器用 entrypoint + volume 挂载天然解决了这些问题，且更轻量。
