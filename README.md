# kyb — kubernate your branches 可以不 ／人◕ ‿‿ ◕人＼

> **野望：让你 10 倍效率的 AI 开发沙箱。**（我们正在往 100 倍走，一起玩？）
>
> ```
> 🐢 古法程序员 ─── 手写代码、手动 CI、手动部署
> 🚀 kyb 当前 ─── Claude Code + 容器开箱即用
> 🌙 下一步 ─── agent 自己看 issue、修 bug、提 MR
> ☀️ 再往后 ─── 数字生命（代码它写，班你上）
> ```

一键创建隔离的 AI 开发沙箱。Docker 容器即用即抛，权限全开无中断，宿主机零污染。

## 安装

三步开箱：

```bash
# 1. 克隆
git clone git@git.leyantech.com:quick-n-dirty/kyb.git ~/.kyb
echo 'export PATH="$HOME/.kyb/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 2. 初始化（把 kyb 自身注册为第一个项目）
cd ~/.kyb && kyb init

# 3. 构建基础镜像（首次 10-15 分钟，网络问题见 docs/network-issues.md）
kyb build

# 4. 创建沙箱
kyb create kyb-hello

# 5. 进入沙箱
kyb enter kyb-hello
```

> `kyb build` 首次构建需 10-15 分钟，网络问题见 [docs/network-issues.md](./docs/network-issues.md)。后续更新：`git -C ~/.kyb pull && kyb build`

### 添加你自己的项目

```bash
cd ~/projects/你的项目
kyb init                    # 注册到 config.yml
kyb create 项目名-功能分支    # 创建沙箱
kyb enter 项目名-功能分支     # 进入沙箱
```

## 架构

```
macOS 宿主机
├── sing-box (socks5:2080)          ← 分流代理
├── ~/.kyb/                          ← 本仓库（clone 到 ~/.kyb）
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
| **外网代理** | CLAUDE.md 中说明 | 宿主机 sing-box, agent 自行配置 |
| **内网** | NO_PROXY 排除 | git.leyantech.com 直连 |
| **用户** | 与 macOS 同名 | 无密码, sudo NOPASSWD, docker 组 |

## 网络原理

```
容器内                        →    宿主机
apt/npm/gem/pip (国内镜像)     →    直连
git clone git.leyantech.com   →    SSH 直连
外网请求                       →    agent 根据 CLAUDE.md 自行配代理
Docker pull                   →    镜像源, 不翻墙
mise 下载 runtime              →    镜像源直接下载
```

## kyb CLI

```bash
kyb build                     # 构建基础镜像
kyb init [NAME]               # 将当前项目加入配置
kyb create <project-branch>   # 创建并启动沙箱（支持 --ports 和 --model）
kyb ps, ls                    # 列出沙箱
kyb enter <project-branch>    # 进入沙箱（支持 --cli claude|kimi|bash）
kyb exec <project-branch> -- CMD
                              # 在沙箱中执行命令
kyb stop <project-branch>     # 停止沙箱
kyb start <project-branch>    # 启动已停止的沙箱
kyb rm <project-branch>       # 删除沙箱
kyb prune                     # 删除所有沙箱
kyb sandbox <project-branch> [PROMPT]
                              # 在宿主机运行 Claude Code sandbox 模式（非 Docker）
kyb did create <name>         # 创建 DID 容器
kyb notify <done|blocked|urgent> <message>
                              # TTS 通知
kyb tts {start|stop|speak|done}
                              # macOS TTS 控制
kyb version                   # 显示版本
```

## 修改沙箱配置

1. 编辑 `Dockerfile`
2. `git commit`
3. `kyb build` 重建基础镜像

## 添加新项目

编辑 `~/.config/kyb/config.yml`：

```yaml
base:
  image: ~/kyb                      # Dockerfile 路径（可选，默认 ~/.kyb）
  kyb_repo: ~/github/kyb            # kyb 项目路径（可选），挂载到容器 /home/dev/kyb 供 agent 读文档
  proxy: socks5://host.orb.internal:2080   # 全局代理（可选）
  no_proxy: .leyantech.com,...      # 全局直连列表（可选）
  claude_default_model: flash       # 默认模型（可选，flash/pro）
  cp_files:                         # 全局 cp_files，所有项目自动生效（可选）
    .env.kyb: .env.kyb              # 大部分项目通用的配置只需定义一次

projects:
  my-project:
    path: "~/path/to/project"       # 项目本地路径
    git_url: "git@github.com:user/repo.git"  # git clone URL（可选，DID 容器参考用）
    base_branch: master             # worktree 基准分支
    ports:                          # 端口映射（可选）
    - 3000:3000
    symlinks:                       # 只读符号链接（可选）
    - shared/vendor
    mounts_rw:                      # 读写挂载（可选）
    - /host/path:/container/path
    mounts_ro:                      # 只读挂载（可选）
    - /host/path:/container/path
    timezone: Asia/Shanghai         # 容器时区（可选，默认 Asia/Shanghai）
    dockerfile: Dockerfile          # 项目级 Dockerfile（可选）
    env_template: .env.example      # 环境变量模板（可选，已废弃，改用 cp_files）
    cp_files:                       # 创建时复制文件到 worktree（可选）
      .env: .env.example            # dest: src（相对项目根路径）
      .env.kyb: .env.kyb            # 源文件不存在自动跳过
    proxy: http://local:3128        # 项目级代理覆盖（可选）
    no_proxy: '*.internal.com'     # 项目级直连列表（可选，覆盖 base.no_proxy）
    sandbox_allowed_domains:        # sandbox 额外域名白名单（可选）
    - '*.internal.corp.com'
    extra_prompt: "项目级提示词"    # 附加到 CLAUDE.md 的提示词（可选）
```

`cp_files` 在 `kyb create` 时从项目目录复制文件到 worktree（容器内项目目录），是 **copy** 不是 bind mount——适合 `.env`、`.env.kyb` 等需要快照进容器、不需要实时同步的文件。旧 `env_template` 仍可用，自动转为 `cp_files` 的 `.env` 项。

三种文件操作方式的选择：

| 机制 | 时机 | 方式 | 适用场景 |
|------|------|------|---------|
| `mounts_ro` / `mounts_rw` | 容器启动 | 实时 mount | 共享代码、数据目录，需要双向同步或实时可见 |
| `symlinks` | 容器启动 | 只读 mount（项目内相对路径） | 共享 vendor 之类只读目录，不用写绝对路径 |
| `cp_files` | `kyb create` | 复制快照到 worktree | `.env`、`.env.kyb` 等一次性配置，不需要随宿主机变化 |

然后 `kyb create <name>` 即可创建沙箱。

## 宿主机挂载

- `~/.ssh` → 容器内 `/home/dev/.ssh` (只读)
- `~/.gitconfig` → 容器内 `/home/dev/.gitconfig` (只读)
- `~/.claude/settings.json` → 容器内 `/home/dev/.claude-host-settings.json` (只读)
- `~/.config/kyb` → 容器内 `/home/dev/.config/kyb` (只读) — 容器内可发现其他项目
- `~/.claude/skills` → 容器内 `/home/dev/.claude-skills-host` (只读)
- `~/.kyb/worktrees/<project>/<container>/` → 容器内 `/home/dev/projects/<project>` (git worktree 隔离)
- `/var/run/docker.sock` → 容器内 Docker 访问

## 共享缓存

所有容器共享命名 volume，数据持久化在宿主机，容器删除不丢失。

| Volume | 挂载点 | 用途 |
|--------|--------|------|
| `kyb-gradle-cache` | `/home/dev/.gradle` | Gradle wrapper + 依赖 |
| `kyb-maven-cache` | `/home/dev/.m2/repository` | Maven 依赖 |
| `kyb-mise-cache` | `/home/dev/.local/share/mise/downloads` | mise 工具链 |
| `kyb-pip-cache` | `/home/dev/.cache/pip` | pip 包 |
| `kyb-swift-cache` | `/home/dev/.local/swift` | Swift 6.2 工具链（可选） |

`kyb build` / `kyb create` / `kyb did create` 时自动检测并使用这些缓存。

## 文本转语音（TTS）

宿主机 macOS 语音服务，容器内通过 `host.docker.internal:10666` 调用。

```bash
curl -X POST http://host.docker.internal:10666/speak \
  -H "Content-Type: application/json" -d '{"text":"你好"}'
```

详见宿主机 `kyb tts` 命令。

## 工作树隔离

每个容器使用独立 git worktree (`~/.kyb/worktrees/<project>/<container>/`)，多实例互不干扰。

## 文档

- [网络问题排查](./docs/network-issues.md) — 构建和运行时所有网络依赖、失败原因和解决方法
- [方案对比](./docs/comparison.md) — kyb vs 其他 AI 沙箱方案，Docker vs sandbox 模式选择
- [OS 级沙箱对比](./docs/os-sandbox.md) — Claude Code / Codex / Zerobox / mise 底层原语深度对比
- [实现踩坑](./docs/sandbox-pitfalls.md) — kyb sandbox 实现过程中遇到的问题和解决方案
- [kyb did 设计](./docs/docker-in-docker.md) — Docker-in-Docker 场景下的容器管理子系统设计
- [容器环境参考](./docs/container.md) — 容器内服务、网络、缓存等详细说明（面向 AI agent）
- [Swift 沙箱测试](./docs/swift.md) — DID 容器跑 Swift 测试的方案和缓存维护
- [终端标题](./docs/terminal-title.md) — iTerm2 标题设置调试记录

## 清理

```bash
kyb rm niao                    # 删除单个沙箱
kyb prune                     # 删除所有沙箱
```
