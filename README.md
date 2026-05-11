# kyb — kubernate your branches ／(◕‿‿◕)＼

一键创建隔离的 AI 开发沙箱。Docker 容器即用即抛，权限全开无中断，宿主机零污染。

## 快速开始

```bash
kyb create niao       # 创建并启动沙箱
kyb enter niao        # 进入沙箱
```

## 架构

```
macOS 宿主机
├── sing-box (socks5:2080)          ← 分流代理
├── ~/kyb/                           ← 本仓库，管理沙箱配置
│   ├── Dockerfile                  ← 沙箱镜像定义
│   ├── entrypoint.sh               ← 容器启动入口
│   └── bin/kyb                     ← CLI 工具
└── Docker 容器
    ├── mise (node, ruby, java...)
    ├── Claude Code (权限全开)
    ├── PostgreSQL 16
    └── ~/projects/                 ← Git 项目 worktree
```

## 容器内配置清单

| 类别 | 方案 | 详情 |
|------|------|------|
| **运行时管理** | mise | 统一管 Node/Ruby/Java 版本 |
| **Node** | node@lts | 通过 mise 安装 |
| **Claude Code** | npm 全局安装 | 权限 `allow: ["*"]` |
| **Docker** | daemon.json 镜像加速 | `docker.1ms.run`, `docker.xuanyuan.me` |
| **包管理器镜像** | 国内源直连 | apt→aliyun, npm→npmmirror, gem→ruby-china, pip→aliyun |
| **外网代理** | ALL_PROXY socks5 | `host.orb.internal:2080` → 宿主机 sing-box |
| **内网** | NO_PROXY 排除 | git.leyantech.com 直连 |
| **用户** | 与 macOS 同名 | 无密码, sudo NOPASSWD, docker 组 |

## 网络原理

```
容器内                        →    宿主机
apt/npm/gem/pip (国内镜像)     →    直连
git clone git.leyantech.com   →    SSH 直连
git clone github.com          →    ALL_PROXY → socks5:2080 (sing-box)
DeepSeek API                  →    ALL_PROXY → socks5:2080
Docker pull                   →    镜像源, 不翻墙
mise 下载 runtime              →    ALL_PROXY → socks5:2080
```

## kyb CLI

```bash
kyb build                     # 构建基础镜像
kyb create NAME [PORT]        # 创建并启动沙箱
kyb ps                        # 列出运行中的沙箱
kyb enter NAME [PORT]         # 进入沙箱
kyb exec NAME [PORT] -- CMD   # 在沙箱中执行命令
kyb stop NAME [PORT]          # 停止沙箱
kyb start NAME [PORT]         # 启动已停止的沙箱
kyb rm NAME [PORT]            # 删除沙箱
kyb prune                     # 删除所有沙箱
```

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`，添加项目配置，然后 `kyb create <name>`。

## 宿主机挂载

- `~/.ssh` → 容器内 `/home/dev/.ssh` (只读)
- `~/.gitconfig` → 容器内 `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → 容器内 `/home/dev/.claude-host-settings.json` (只读)
- `~/projects` → 容器内 `/home/dev/projects`
- `/var/run/docker.sock` → 容器内 Docker 访问

## 工作树隔离

每个容器使用独立 git worktree (`~/.kyb/worktrees/<project>/<container>/`)，多实例互不干扰。详见 `docs/multi-sandbox-worktree.md`。

## 清理

```bash
kyb rm niao                    # 删除单个沙箱
kyb prune                     # 删除所有沙箱
```
