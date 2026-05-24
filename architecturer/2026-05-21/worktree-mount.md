# Worktree 已死，Mount 当立

**日期：** 2026-05-21
**变更：** git worktree 从 kyb 中彻底移除

## 起因

容器里的 agent 总在 worktree 上被 git 卡住。`git pull`、`git rebase`、`git checkout` 全都不行。agent 一脸懵："这 repo 怎么回事？"

## 设计演化

1. 先想 clone 进容器 → iOS 外面要 build，不通
2. 又想直接 mount 全目录 → 用户项目散落各处
3. 还想搞 `--clone` 模式 → 全 agent 隔离 vs 共享 mount

**最终方案：**
- **默认：** 宿主 repo 直接 rw mount 进容器
- **`--clone`：** git clone 独立副本，适合并行开发
- **`kyb rm`** 不再碰 git，只删容器
- 删掉整个 sandbox 模式

## 变更规模

- 6 个 lib 文件改动，2 个完全删除（`git.rb` + `sandbox.rb`）
- 9 个测试文件更新
- `entrypoint.sh` + CI 配置同步修
- 最终 212 测试全绿 + smoke test 通过

## 核心理念

> 砍需求才是最好的设计。

Worktree 试图解决一个**根本不存在的问题**——大部分场景下，宿主不需要和容器并行操作同一个 repo。
