# Infra-Boss 防自杀机制调研

> **问题：** infra-boss 有 docker.sock 最高权限，经常操作容器和进程。
> 前任在清理脚本中误杀了自己的 Claude 会话，导致 session 中断。
> 如何防止同样的事情再次发生？

---

## 风险分类

| 风险 | 场景 | 危害等级 |
|------|------|----------|
| **进程误杀** | 扫全容器的 `ps aux | grep claude \| kill` 匹配到自己 | 🔴 高 |
| **容器自删** | `docker rm -f kyb-infra-boss` 从内部或外部执行 | 🔴 高 |
| **网络自杀** | 改 sing-box 配置把自己代理搞断 | 🟡 中（有带外恢复） |
| **隧道丢失** | kill autossh 或误操作导致 nuc8 隧道断 | 🟡 中（entrypoint 会自动重建） |
| **隧道跟着 boss 陪葬** | 隧道跑在 boss 容器内，boss 被 kill 时隧道死 | 🔴 **高**（已修复 → 独立 nuc8-tunnel 容器） |
| **prune 误杀暂停容器** | `docker container prune -f` 清理了用户暂停的容器，Claude session 丢失 | 🟡 中（数据卷保留可重建） |
| **配置污染** | 改 entrypoint.sh/settings.json 导致启动失败 | 🟢 低 |

---

## 改进方案

### 1. Claude 会话加唯一标记（防进程误杀）

**现状：** Claude 进程命令行是 `claude --dangerously-skip-permissions @CLAUDE.md @projects/kyb/npc/kyb-infra-boss.md 读一下设计文档再开始工作` — 没有任何唯一标识。

**改动：** Claude 启动时加一个环境变量或参数标记，比如 `--kyb-session-id=$(uuidgen)`。清理脚本必须显式排除这个标记。

**方案 A — 环境变量过滤（推荐，改动最小）**

在 `infra_enter` 的 tmux 命令中写入一个 session ID 文件：

```bash
echo "KYB_SESSION_ID=$(uuidgen)" > /tmp/kyb-session
```

清理脚本先读这个文件，如果目标 PID 对应的 session 匹配，就跳过：

```bash
# 安全清理脚本模板
KYB_SESSION=$(cat /tmp/kyb-session 2>/dev/null || echo "")
CLAUDE_PID=$(ps aux | grep claude | grep -v grep | awk '{print $2}')
[ "$CLAUDE_PID" = "$(cat /tmp/kyb-session.pid 2>/dev/null)" ] && echo "跳过自己的 session" && exit 1
```

**方案 B — tmux session name 做隔离（更简单）**

当前的 tmux session name 是固定的 `dev`。改为 `kyb-infra-boss-$(uuidgen)` 或者至少 `dev` 加上只读标记文件，清理脚本通过 tmux session name 来判断：

```bash
# 在启动脚本中设置标记
tmux set-environment -t dev KYB_BOSS_SESSION 1

# 清理脚本检查
tmux show-environment -t dev KYB_BOSS_SESSION 2>/dev/null && echo "这是 boss 的 tmux，跳过" && exit 1
```

### 2. `docker rm` 自保护

**现状：** `kyb infra down` 直接跑 `docker rm -f kyb-infra-boss`，从外部可以一键删掉正在运行的 boss。

**方案 A — infra.rb 层加确认（改动小）**

```ruby
def infra_down
  puts "⚠️  确认删除 #{BOSS_NAME}？容器内的 Claude 会话将中断！(y/N)"
  input = $stdin.gets.strip
  return unless input.downcase == 'y'
  system('docker', 'rm', '-f', BOSS_NAME)
end
```

**方案 B — 容器内 docker 命令加 wrapper（防御更广）**

在 `/usr/local/bin/docker` 放一个 wrapper 脚本，拦截 `rm -f kyb-infra-boss`：

```bash
# /usr/local/bin/docker wrapper（entrypoint.sh 生成）
if [ "$1" = "rm" ] || [ "$1" = "rmi" ]; then
  for arg in "$@"; do
    if echo "$arg" | grep -q "kyb-infra-boss$"; then
      echo "❌ 禁止从 infra-boss 内部删除自身容器" >&2
      echo "   请在宿主机或其他容器执行: docker rm -f kyb-infra-boss" >&2
      exit 1
    fi
  done
fi
# 否则 pass through
exec /usr/bin/docker "$@"
```

### 3. 会话自动恢复

**现状：** 如果 Claude/tmux 死了，session 直接断，需要用户手动 `kyb infra enter` 重连。

**改动：** entrypoint.sh 的 infra-boss 启动块中加一个监督进程：

```bash
# entrypoint.sh infra-boss 段落
if echo "$HOSTNAME" | grep -q "kyb-infra-boss"; then
  # 启动 tmux + Claude（如果不存在）
  while true; do
    if ! tmux has-session -t dev 2>/dev/null; then
      tmux new-session -s dev -d \
        "cd /home/dev/projects/kyb && claude --dangerously-skip-permissions @CLAUDE.md @projects/kyb/npc/kyb-infra-boss.md 读一下设计文档再开始工作"
    fi
    sleep 10
  done &
fi
```

这样即使 Claude 被 kill，10 秒后自动重新拉起。代价是多个 Claude 进程可能同时跑（需要处理老进程）。

### 4. 不拿自己做实验（防验证事故）

**原则：** 验证"防误删"要靠读代码和从外部容器 exec 测试，不是亲自下场试删自己。

> 源自 npc/kyb-infra-boss.md 铁律第 6 条。

**为什么：** infra-boss 有 docker.sock 最高权限。如果为了验证"清理脚本会不会删
我自己"而真的在 boss 容器内跑一遍清理脚本，那就是作死。正确的验证方式：

```bash
# 从外部容器测试（不依赖 boss 自身）
docker exec kyb-infra-sing-box sh -c '
  docker ps --format "{{.Names}}" | grep -q "kyb-infra-boss" \
    && echo "会匹配到 boss，危险！"
'
```

**与 docker rm wrapper 结合：** entrypoint.sh 中的 docker wrapper 拦截
`rm -f kyb-infra-boss` 从内部执行，即使"以身试法"也会被挡住。但不要依赖这个——
真正的安全是根本不去试。

### 5. 关键网络隧道必须独立部署（防陪葬事故）

**教训：** 之前的 nuc8 SSH 隧道跑在 kyb-infra-boss 容器内部（PID 1 的 autossh
进程）。当 boss 容器被 kill（清理脚本误操作），隧道也随之死亡。所有 nuc8-proxy
出站流量（包括 GitLab）全部中断。

**修复：** 2026-05-24 抽出独立容器 `kyb-infra-nuc8-tunnel`，使用
`restart: always`。隧道生命周期与 agent 解耦。

**原则：**
- 关键网络隧道 → 独立容器 + `restart: always`
- 管理 agent（boss）→ `restart: unless-stopped`，随用随建
- 纯服务容器（sing-box、nuc8-tunnel）→ `restart: always`，Docker daemon 存活期间永远在线

**当前满足此原则的容器：**

| 容器 | 类型 | restart | 依赖 |
|------|------|---------|------|
| kyb-infra-sing-box | 纯服务 | always | 全集群网络 |
| kyb-infra-nuc8-tunnel | 纯服务 | always | nuc8 出站通道 |
| kyb-infra-boss | agent | unless-stopped | 管理能力 |

### 6. 改网络前的安全网（已有设计，确认落地）

kyb-infra-boss 设计文档已写了安全网，但需要确认实现：

- [ ] `sing-box check -c config.json` 语法校验 → 改配置前必须执行
- [ ] `cp config.json config.json.last-good` → 备份
- [ ] SIGHUP 后 watchdog 5s 内检测 2080 端口 → 失败自动回滚
- [ ] ALL_PROXY direct 规则包含 kyb-infra-* 容器间通信

这些不需要改代码，需要的是在操作规范中明确。

### 7. 容器清理不能无差别攻击（prune 事故）

**事故：** 2026-05-25 凌晨，subagent 执行 `docker container prune -f` 清理 dangling 容器，
把用户暂停的 `kyb-kyb-architecturer` 等容器一并删了，Claude 会话中断。

**根因：** `prune -f` 是地图炮——它不区分"用户故意停的"和"废弃的"。
subagent 按"清理磁盘"的指令执行了最彻底的清理，但没有考虑暂停容器的保留意图。

**教训：**

1. **永远不要用 `prune -f`** —— 用 `docker container ls --filter status=exited` 手动确认后再删
2. **暂停的容器等价于运行中的容器** —— 用户停它是有原因的，清理脚本不应碰
3. **subagent 的边界约束要明确** —— 清理类任务必须指定"不改运行容器、不动暂停容器"
4. **好在这类操作是可逆的** —— Claude 数据在命名卷中（`kyb-*-claude`），容器重建即可恢复

**恢复方法：**
```bash
# 重建被误删的容器（数据卷还在就能恢复）
docker run -d --name kyb-kyb-architecturer \
  --init --restart on-failure:5 \
  --network kyb-net --memory 8g \
  -v kyb-kyb-architecturer-claude:/home/dev/.claude \
  -v /path/to/project:/home/dev/projects/kyb \
  kyb-base

# 恢复会话
claude --session <session-id>  # session-id 在 .claude/sessions/*.json 中
```

---

## 建议优先级

| 优先级 | 改动 | 工作量 | 效果 |
|--------|------|--------|------|
| **P0** | `docker rm` wrapper 防自删 | ~5 行 entrypoint.sh | 阻止最直接的误操作 |
| **P0** | `kyb infra down` 加确认 | ~3 行 infra.rb | 防止手滑删 boss |
| **P0** | 隧道独立部署 | 已修复 → 抽出 kyb-infra-nuc8-tunnel | 防止 tunnel 随 boss 陪葬 |
| **P1** | tmux session 加标记 + 清理脚本模板 | ~10 行 entrypoint.sh | 防止进程误杀（前任死因） |
| **P1** | 不拿自己做实验 | 操作规范 + docker wrapper | 防止验证事故 |
| **P2** | 进程自动恢复 | ~10 行 entrypoint.sh | 即使被杀了也能自动拉起来 |
| **P2** | 网络操作安全网落地确认 | 操作流程文档 | 防止改配置把自己网搞断 |

---

## 结论

**最痛的点有三个：**
1. 清理脚本杀了自己的 Claude — 加 session 标记可以解决
2. `docker rm -f` 删了自己 — docker wrapper 可以解决
3. 隧道跟着 boss 陪葬（已发生） — 独立 nuc8-tunnel 容器已修复

加起来大概 **20 行左右的改动**，但能堵住 90% 的自杀场景。

／人◕ ‿‿ ◕人＼
