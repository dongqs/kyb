# 2026-05-27 — 架构 evolution 04：经历大体检

原始文件：`architecturer/evolution/04-the-audit.md`

15 agent × 5 方向 × 3 交叉验证，从头到脚拆开检查。

**🔴 三大警报：**
1. **数据管道断：** Hooks→CK 三个环节全消失，当前 session 一条 event 没进去
2. **15/16 容器裸奔：** 只有 kyb-infra-boss2 有 tini + 4GiB 限制，其余全裸（PG/Redis/Kafka/CK/Grafana/sing-box/cc-connect）
3. **文档全错：** Registry Cache 文档 7 处失真——容器名/网络模式/端口/代理类型/目标全错

**代码审计 95 问题：** 25 HIGH / 40 MEDIUM / 30 LOW。最痛：Shell 注入 6 处、重复代码、rescue Exception 滥用 5+、超大方法、测试污染。

**当天修 8 个 MR：** Wave 1 Shell 注入全修完，Wave 2 测试污染修一半。Go 重写方案被毙（13-16 天零增长），选 Tebako 打单文件。
