# 2026-05-27 — 架构 evolution 06：自愈能力

原始文件：`architecturer/evolution/06-self-healing.md`

**四个反复发作的病，同一个根因：** 容器重建后手动配置丢失。

| 病 | 修法 |
|---|------|
| nuc8 隧道断了 | entrypoint.sh 自动 autossh 建隧道+断线重连 |
| sing-box 端口忘映射 | 记文档，长期用 docker-compose/stack |
| sing-box 落默认网段 | 重建加 `--network kyb-net` |
| 配置指向死 IP | 从宿主机只读 mount 读配置 |

全部修复方向：**放到 entrypoint.sh 里自动恢复。**

**巡检免疫系统：** 3 个 patrol × 15 分钟间隔，互相关心跳。一个不写另外两个报。

**5 条健康检查：** docker ps → 容器在；curl via proxy → 外网通/内网通；ss → 隧道在；df → 磁盘够。

**prune 事故教训：** subagent 执行 `docker container prune -f` 误删所有暂停容器。教训：永远不用 `prune -f`，用 `--filter status=exited`；暂停容器等价于运行中；清理类任务必须指定边界约束。
