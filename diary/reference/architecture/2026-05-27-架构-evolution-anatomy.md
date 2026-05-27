# 2026-05-27 — 架构 evolution anatomy：系统解剖

原始文件：`architecturer/evolution/anatomy/{code,data-flow,dispatch,memory,security,topology}.md`

**代码结构：** `bin/kyb` → `lib/kyb/`（kyb.rb, config, parser, docker, container, proxy, reporter, exit_flow, check, tts_server）+ `cli/`（8 命令）。0 gem 依赖，Tebako 单文件。最烂：Docker.run 115 行、create_container 110+。

**数据管道：** Agent → Claude Hooks → emit-ck.sh → HTTP POST → CK(kyb.agent_events) → Grafana 48 面板 + 7 告警 + Patrol 巡检。断过三次，现在 entrypoint.sh 自动恢复。

**调度模型：** Boss 拆任务 → N agent 并行 → 交叉验证。阈值：<1s 自己做，>1s 派活，>60s 多 worldview。调度第一定律：无法验收的任务不派。第二定律：验收成本过高等于无法验收。核心经济模型：ROI = 熵产出 ÷ 上下文消耗。人类短生种（密度/迭代），电子人长生种（积累/存储），互补不是噱头是同一系统不同组织。

**记忆四层：** Layer 0 金鱼脑子（上下文窗口）→ Layer 1 Memory（3h 文件系统）→ Layer 2 CK（30d agent_events）→ Layer 3 文档（永久 git）。每遇到一个问题加一层。

**安全边界：** macOS 完全信任 → infra-boss 半信任(有 Docker socket) → Sandbox 不信任(用户代码)。已修 6 处注入面(反引号/容器名/heredoc/sed)。待修：API key 通过 -e 传(ps aux 可见)、rescue Exception 吞 Signal、无容器创建限流、NO_PROXY 未设。

**拓扑：** kyb-net(192.168.97.x) 内 8 个 infra 容器互通。Sandbox 容器 → host.orb.internal:2080(socks5) → sing-box → 直连/nuc8 隧道。
