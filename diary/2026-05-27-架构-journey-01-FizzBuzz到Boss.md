# 2026-05-27 — 架构 journey 01：从 FizzBuzz 到 Boss Mode

原始文件：`architecturer/journey/01-first-contact.md` — 2026-05-21 Day 1

始于一场 FizzBuzz（6 agent × 6 语言，Perl 5.6s 赢），引出 17 项目一夜清盘。

**当天被纠正至少十次**，凝成五条铁律：不等（>1s 派活）、不替（不替 subagent 写代码）、不堵（70% 决策）、不确定就多派人、假设 agent 在骗你。

**砍 Worktree：** agent 被 worktree 卡死 → 砍掉 worktree+sandbox 模式 → 默认 mount。砍了才意识到 worktree 解决的问题不存在。

**17 项目一夜清盘：** 12+ agent 同时跑，12 全四轮收敛。新镜像 `54b6869079f5` 凌晨五点上线。系统是活的。
