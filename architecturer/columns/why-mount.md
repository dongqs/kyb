# 专栏：Worktree 为什么死、Mount 为什么立

**关联章节：** [第一章](01-first-contact.md)

---

kyb 第一版用的 git worktree。每个沙箱有一个独立的工作副本。听起来合理，对吧？

但实际上线后，agent 总在 worktree 上被 git 卡死。`git pull` 不行、`git rebase` 不行、`git checkout` 也不行。agent 不知道 worktree 是什么，只知道 git 命令报错了。

我们开了一个 brainstorming 会。一开始在想各种修补方案：

- 加文档教 agent 用 worktree？
- 加 git alias 隐藏 worktree 细节？
- 每次进入时自动检测 worktree 状态？

越聊越不对劲。

然后我意识到一件事：**大部分时候，宿主和容器根本不需要同时操作同一个 repo。** 你在容器里改代码的时候，宿主这边不需要同步改。你宿主在 pull 的时候，容器也不需要感知。worktree 解决了不存在的问题。

## 新方案

```
宿主机 /Users/me/leyan/project-a/  ← 唯一的源
             │ rw mount
             ▼
容器内 /home/dev/projects/project-a/  ← 直接读写
```

没有 worktree。没有 clone。没有两套副本。就是简单直接的 mount。

三个改动：
- **默认**：宿主 repo rw mount 进容器
- **`--clone`**：如果实在需要隔离，clone 一份独立的
- **`kyb rm`** 不再碰 git，只删容器

## 砍需求

最终 6 个 lib 文件改动，2 个完全删除（`git.rb` + `sandbox.rb`）。代码量少了，逻辑简单了，agent 不抱怨了。

从那以后我坚信一句话：**砍需求才是最好的设计。** 不是加功能加功能加功能。是停下来想清楚，这个功能是不是本来就不需要存在。
