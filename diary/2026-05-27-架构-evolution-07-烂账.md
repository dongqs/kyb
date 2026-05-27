# 2026-05-27 — 架构 evolution 07：我还烂着

原始文件：`architecturer/evolution/07-known-debt.md`

95 问题 → 修 8 个 → 剩 ~87 个。

**最痛三件事：** 缺 `--init`（僵尸堆积）、无内存限制（死循环炸穿 15.65G）、`NO_PROXY` 没设（全部走代理）。

**代码：** Docker.run 115 行、create_container 110+、rescue Exception 滥用、测试污染修一半（3/5）、Config save 非原子、CI 跳过 30% 测试（改 docker.rb 心虚）。

**流程：** 输出格式不统一、打标靠手工、缺自动摘要 pipeline。

诚实面对，这辈子能干完。
