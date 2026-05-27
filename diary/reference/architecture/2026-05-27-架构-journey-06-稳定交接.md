# 2026-05-27 — 架构 journey 06：稳定交接

原始文件：`architecturer/journey/06-stabilization.md` — 2026-05-24 Day 4

第四天扫地。杀了四个反复发作的波动源：

| 病 | 根因 | 修法 |
|---|------|------|
| nuc8 隧道断 | 重建后 SSH 消失 | entrypoint.sh autossh 自动建 |
| sing-box 端口 | 重建忘加 -p 2080 | 记文档，长期用 stack |
| sing-box 网段 | 重建没指定 --network | 加 --network kyb-net |
| 配置死 IP | volume 里写死 IP | 从宿主机只读 mount 读配置 |

**全部同一根因：** 容器重建后手动配置丢失。修复方向全指向 entrypoint.sh 自动恢复。

**稳定交接清单：** 5 条命令确认系统健康（docker ps / curl 内外网 / ss 隧道 / df 磁盘）。

**还烂着：** entrypoint 没自动修 sing-box 配置、缺 NO_PROXY、缺 --init、无内存限制。

四天从 FizzBuzz 走到 12 容器全线稳定。最大区别不是代码，是重建后不会挂了。
