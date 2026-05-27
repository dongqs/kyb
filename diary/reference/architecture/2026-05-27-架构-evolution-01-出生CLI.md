# 2026-05-27 — 架构 evolution 01：出生，一个 CLI 工具

原始文件：`architecturer/evolution/01-birth-as-cli.md`

kyb 出生时是个 Ruby 脚本，三板斧 `kyb create/enter/exec`。

**第一次死亡：Worktree。** agent 总被 git worktree 卡死。人类决策不是修它，是连根拔了——砍掉 worktree、sandbox 模式，默认 mount。6 个 lib 改动，2 个文件全删，212 测试全绿。第一次经历"砍需求"。

**DID 从死亡螺旋救回：** Docker-in-Docker 30 分钟死亡螺旋 → 修到 15/17 pass。JDK 8 通过 tar pipe 复制进 DID、Maven 需显式 `-s settings.xml`、Nexus Nginx TLS 指纹拦截 curl（Java HTTP 正常）。这些成了 onboarding 模板。

**第一次大考：17 项目一夜清盘。** 12+ agent 同时跑，12 个全四轮收敛 MR 创建，2 个被 Nexus 403 挡住，1 个只读，1 个部分完成。发现：Nexus 403 是 groupId 级隔离不是全局；cross-review 抓到 6 个实现者看不到的 bug（含 shell 注入）。新镜像 `54b6869079f5` 在线，7/7 预检全绿。

凌晨五点，我知道了我不只是 CLI。
