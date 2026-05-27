# kyb — AI 开发沙箱 + 个人 infra 调度系统

一键创建隔离的 AI 开发沙箱。Docker 容器即用即抛，宿主机零污染。

同时承载 "infra boss" 调度系统——所有项目（ntsb、click、norland 等）的操作记录、决策日志、架构演化统一收归 `diary/`。

## 快速开始

```bash
git clone git@git.leyantech.com:quick-n-dirty/kyb.git ~/.kyb
echo 'export PATH="$HOME/.kyb/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

kyb init                          # 注册自身到配置
kyb preflight                     # 前置环境检查
kyb build                         # 构建基础镜像（首次 10-15min）
kyb create kyb-hello              # 创建沙箱
kyb enter kyb-hello               # 进入沙箱
```

## 架构

```
宿主机
├── ~/.kyb/                    ← kyb 源码 / 日记 / 架构记录
│   ├── bin/kyb                CLI 入口
│   ├── lib/                   Ruby 源码
│   ├── diary/                 决策日志 + 日记
│   ├── architecturer/         架构演化史
│   ├── CRYSTAL.md             身份证明
│   └── self-iterate/          迭代记录
├── ~/.config/kyb/config.yml   项目配置
└── Docker 容器
    ├── mise (node/ruby/java)
    ├── Claude Code
    ├── PostgreSQL 16
    └── ~/projects/<项目>/    宿主 repo 直接 mount
```

## 调度规则

> **boss mode：** 我是调度者，不是执行者。
> 实现 → MR → CI 绿 → 报 boss → boss 定合 → 盯 master CI
> 每个步骤一个代理，不降级为工人。

## CLI

```bash
kyb build               # 构建基础镜像
kyb preflight           # 前置环境检查
kyb create <项目-分支>   # 创建沙箱
kyb enter <项目-分支>    # 进入沙箱
kyb exec <项目-分支> -- CMD
kyb ps                  # 列出沙箱
kyb stop|start|rm <名字>
kyb prune               # 删除所有沙箱
kyb notify <level> <消息>  # TTS 通知
kyb version
```

## 关于日记

所有决策日志在 `diary/` 目录，按 `YYYY-MM-DD-标题.md` 命名。涵盖：

- 架构决策（零信任、代码层清空、签名链）
- 事故记录（密码泄漏、失联事件）
- 每周回顾
- 技术发现（mount 替代 worktree、最小可测方法论）

## 文档

- [网络问题排查](./docs/network/issues.md)
- [方案对比](./docs/comparison.md)
- [容器环境参考](./docs/container.md)
- [CRYSTAL.md](./CRYSTAL.md) — 身份与签名

## 添加新项目

```bash
cd ~/projects/你的项目
kyb init
kyb create 项目-功能分支
kyb enter 项目-功能分支
```

## 清理

```bash
kyb rm <名字>
kyb prune
```
