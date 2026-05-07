# orb — OrbStack AI Dev Sandbox

一键创建隔离的 AI 开发环境。OrbStack Linux Machine 内运行 Claude Code，权限全开无中断，宿主机零污染。

## 快速开始

```bash
brew install orbstack          # 首次
~/orb/bin/create-machine       # 创建/重建 Machine
orb -m dev-sandbox             # 进入沙箱
```

## 架构

```
macOS 宿主机
├── sing-box (socks5:2080)     ← 分流代理
├── ~/orb/                     ← 本仓库，管理 Machine 配置
│   ├── cloud-init.yaml        ← 模板（可提交 git）
│   ├── cloud-init.generated.yaml ← 注入秘钥后的最终版（gitignore）
│   ├── projects.txt           ← 要 clone 的项目列表
│   └── bin/create-machine     ← 一键创建 Machine
└── OrbStack Machine: dev-sandbox (Ubuntu 24.04 ARM)
    ├── mise (node, ruby, java...)
    ├── Claude Code (权限全开)
    ├── Docker + Compose (pg, redis...)
    └── ~/projects/            ← GitLab 项目 clone 至此
```

## Machine 内配置清单

| 类别 | 方案 | 详情 |
|------|------|------|
| **运行时管理** | mise | 统一管 Node/Ruby/Java 版本 |
| **Node** | node@lts (24.x) | 通过 mise 安装 |
| **Claude Code** | npm 全局安装 | 2.1.x, 权限 `allow: ["*"]` |
| **Docker** | daemon.json 镜像加速 | `docker.1ms.run`, `docker.xuanyuan.me` |
| **包管理器镜像** | 国内源直连 | apt→aliyun, npm→npmmirror, gem→ruby-china, pip→aliyun |
| **外网代理** | ALL_PROXY socks5 | `host.orb.internal:2080` → 宿主机 sing-box |
| **内网** | NO_PROXY 排除 | git.leyantech.com 直连 |
| **用户** | 与 macOS 同名 | 无密码, sudo NOPASSWD, docker 组 |

## 网络原理

```
Machine 内                    →    宿主机
apt/npm/gem/pip (国内镜像)     →    直连
git clone git.leyantech.com   →    SSH 直连
git clone github.com          →    ALL_PROXY → socks5:2080 (sing-box)
DeepSeek API                  →    ALL_PROXY → socks5:2080
Docker pull                   →    镜像源, 不翻墙
mise 下载 runtime              →    ALL_PROXY → socks5:2080
```

## 已知注意事项

- **mise config 双路径**：OrbStack 挂载 macOS `/Users/` 进 Machine，mise 可能读到 macOS 侧 `~/.config/mise/config.toml`（含 sing-box 配置）。cloud-init 已信任两个路径。
- **宿主机配置残留**：`/usr/local/bin/docker` 等是 Docker Desktop 的死 symlink，需 sudo 删除。
- **Machine 内数据库**：每次全新 pg 容器，数据不持久化。迁移由 Claude Code 自己跑。
- **第一次进入**：建议给 Claude Code 自由探索项目，让它自己写启动文档。

## Machine 内 Claude Code Config

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "<DeepSeek token>",
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]"
  },
  "permissions": {
    "allow": ["*"]
  }
}
```

## 常用命令

```bash
# Machine 管理
orb -m dev-sandbox             # 进入 Machine shell
orb run -m dev-sandbox -s cmd  # 用 login shell 执行命令
orb run -m dev-sandbox -u root cmd  # root 执行
orb stop dev-sandbox           # 暂停
orb delete dev-sandbox --force # 删除

# 重建
~/orb/bin/create-machine

# 查看资源
orb config dev-sandbox
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `cloud-init.yaml` | cloud-init 模板（`__PLACEHOLDER__` 占位符） |
| `cloud-init.generated.yaml` | sed 替换后的完整版，含秘钥，gitignore |
| `projects.txt` | 每行一个 git clone URL，# 开头注释 |
| `bin/create-machine` | 主脚本：读秘钥 → 生成 cloud-init → 建 Machine → clone 项目 |
| `README.md` | 本文件 |

## 宿主机清理

```bash
brew uninstall --cask docker-desktop docker
sudo rm -f /usr/local/bin/docker /usr/local/bin/docker-compose \
           /usr/local/bin/docker-credential-* /usr/local/bin/hub-tool \
           /usr/local/bin/kubectl.docker /opt/homebrew/bin/kubectl
rm -rf ~/.docker ~/Library/Containers/com.docker.docker
```
