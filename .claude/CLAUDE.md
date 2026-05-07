# CLAUDE.md — orb

OrbStack AI 开发沙箱配置仓库。管理 `dev-sandbox` Machine 的 cloud-init、项目列表、创建脚本。

## 关键文件

- `cloud-init.yaml` — cloud-init 模板，`__PLACEHOLDER__` 格式的占位符由 `bin/create-machine` 用 sed 替换为宿主机秘钥
- `bin/create-machine` — 主脚本，读宿主机秘钥 → 生成 cloud-init → 删旧 Machine → 建新 Machine → wait ready → clone 项目
- `projects.txt` — 要 clone 的项目 URL 列表，# 开头为注释
- `cloud-init.generated.yaml` — gitignored，包含实际秘钥

## 常用操作

- 创建/重建 Machine: `~/orb/bin/create-machine`
- 进入 Machine: `orb -m dev-sandbox`
- Machine 内跑命令: `orb run -m dev-sandbox -s <cmd>`
- root 执行: `orb run -m dev-sandbox -u root <cmd>`
- 查看 Machine 状态: `orb list`
- 删除 Machine: `orb delete dev-sandbox --force`

## 修改 Machine 配置

1. 编辑 `cloud-init.yaml`
2. `git commit`
3. `~/orb/bin/create-machine` 重建

## 添加新项目

1. 编辑 `projects.txt`，加一行 git clone URL
2. 重建 Machine，或手动进入 Machine `git clone`

## cloud-init 迭代教训

- Ubuntu 24.04 apt 源用 deb822 格式（`/etc/apt/sources.list.d/ubuntu.sources`），不是老式 sources.list
- cloud-init 的 `encoding: base64` 对多行私钥不可靠，用 `base64 -d` 在 runcmd 里手动解码
- runcmd 中的 `su - USER` 需要 .bash_profile 来 source .bashrc（login shell 不自动读 .bashrc）
- user 创建用 cloud-init `users` 模块，确保在 write_files/runcmd 之前用户已存在
- chown 必须在 `su - USER` 之前执行，否则用户写不了自己的 home
- OrbStack 挂载 macOS `/Users/` 到 Machine，mise 会发现两个 config.toml（macOS + Linux），需要都 trust
- ~ 在 `$()` 中不展开，用 `$HOME`
- `orb create` 的 cloud-init flag 是 `-c` / `--user-data`，不是 `--cloud-init`
