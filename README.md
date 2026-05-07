# orb — OrbStack AI Dev Sandbox

一键创建隔离的 AI 开发环境。OrbStack Linux Machine 内运行 Claude Code，权限全开无中断，宿主机零污染。

## 前置条件

```bash
brew install orbstack  # 如果还没装
```

## 创建/重建 Machine

```bash
~/orb/bin/create-machine
```

脚本做的事：

1. 从宿主机读取 SSH key、DeepSeek API token、Git 配置
2. 生成 cloud-init 注入 Machine
3. 创建 Ubuntu 24.04 Machine（CPU 共享、RAM 8GB 起可调、磁盘 80GB）
4. Machine 内自动安装 mise、Node LTS、Claude Code、Docker
5. Clone `projects.txt` 中列出的所有仓库
6. 配置无密码 sudo、Docker 权限、SSH key

## 进入开发

```bash
orb ssh dev-sandbox
cd ~/projects/<project>
claude
```

## Machine 内 Claude Code 的行为

- 权限全部放行（Machine 本身是隔离层）
- 用 Docker Compose 启动 PostgreSQL/Redis 等开发服务
- 自己跑 mig25 建表、跑 test、git push
- 没有 Mac 弹窗中断

## 资源调整

```bash
orb config dev-sandbox   # 调 CPU/RAM/disk
```

## 玩坏了重建

```bash
~/orb/bin/create-machine   # 自动删旧建新
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `cloud-init.yaml` | cloud-init 模板（含占位符，可提交 git） |
| `cloud-init.generated.yaml` | 注入秘钥后的最终文件（.gitignore 排除） |
| `projects.txt` | 要 clone 的项目列表 |
| `bin/create-machine` | 创建 Machine 的主脚本 |

## 宿主机清理

安装 OrbStack 后可移除 Docker Desktop：

```bash
brew uninstall --cask docker-desktop
rm -rf ~/.docker ~/Library/Containers/com.docker.docker
```
