# 运行时层 — {new-machine-remote-hostname}

我是谁：记录 remote:ssh {new-machine-ssh-user}@{new-machine-ssh-host} 的开发工具链。
我在哪：remote:~/.claude/docs/04-runtime.md
我要干什么：盘点语言运行时、包管理器、CLI 工具的安装情况。
我不干什么：不记录系统服务、硬件。

## 语言运行时

> 📝 操作提示：运行审计脚本批量检查，然后填表 commit。

```bash
# === local ===
cat > /tmp/kyb-{ts}-rt-lang.sh << 'SCRIPT'
for tool in ruby python3 node java go rustc dotnet; do
  ver=$($tool --version 2>/dev/null | head -1)
  [ -n "$ver" ] && echo "$tool: $ver" || echo "$tool: NOT INSTALLED"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 工具 | 已装 | 版本 | 安装方式 |
|------|------|------|---------|
| Ruby | Y / N | ______ | system / mise / rbenv / brew / 未装 |
| Python 3 | Y / N | ______ | system / mise / pyenv / brew / 未装 |
| Node.js | Y / N | ______ | system / mise / nvm / brew / 未装 |
| Java | Y / N | ______ | system / mise / sdkman / brew / 未装 |
| Go | Y / N | ______ | system / brew / 手动 / 未装 |
| Rust | Y / N | ______ | rustup / 手动 / 未装 |
| .NET | Y / N | ______ | 未装 |

### 确认

我确认以上语言运行时信息正确。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 包管理器

```bash
# === local ===
cat > /tmp/kyb-{ts}-rt-pkg.sh << 'SCRIPT'
for tool in mise npm pip gem cargo; do
  ver=$($tool --version 2>/dev/null | head -1)
  [ -n "$ver" ] && echo "$tool: $ver" || echo "$tool: NOT INSTALLED"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 工具 | 已装 | 版本 |
|------|------|------|
| mise | Y / N | ______ |
| npm | Y / N | ______ |
| pip | Y / N | ______ |
| gem | Y / N | ______ |
| cargo | Y / N | ______ |
| go (模块管理) | Y / N | 同上 |
| 其他______ | Y / N | ______ |

### 确认

我确认以上包管理器信息正确。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 常用 CLI

```bash
# === local ===
cat > /tmp/kyb-{ts}-rt-cli.sh << 'SCRIPT'
for tool in git docker docker-compose kubectl helm tailscale jq yq htop tmux nvim vim curl wget dig nc rsync ssh sqlite3 redis-cli psql mysql make gcc cmake glab gh; do
  ver=$($tool --version 2>/dev/null | head -1)
  [ -n "$ver" ] && echo "$tool: $ver" || echo "$tool: NOT INSTALLED"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 工具 | 已装 | 版本 |
|------|------|------|
| git | Y / N | ______ |
| docker | Y / N | ______ |
| docker compose | Y / N | ______ |
| kubectl | Y / N | ______ |
| helm | Y / N | ______ |
| tailscale | Y / N | ______ |
| jq | Y / N | ______ |
| yq | Y / N | ______ |
| htop / btop | Y / N | ______ |
| tmux | Y / N | ______ |
| neovim / vim | Y / N | ______ |
| curl | Y / N | ______ |
| wget | Y / N | ______ |
| dig / nslookup | Y / N | ______ |
| nc / netcat | Y / N | ______ |
| rsync | Y / N | ______ |
| ssh | Y / N | ______ |
| sqlite3 | Y / N | ______ |
| redis-cli | Y / N | ______ |
| psql | Y / N | ______ |
| mysql / mariadb client | Y / N | ______ |
| glab / gh | Y / N | ______ |
| make | Y / N | ______ |
| gcc / clang | Y / N | ______ |
| cmake | Y / N | ______ |
| 其他______ | Y / N | ______ |

### 确认

我确认以上 CLI 工具清单完整。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 探索日志

| # | 时间 (精确到秒) | 操作 | 结果 | 耗时 | commit |
|---|------|------|------|------|--------|
| 1 | | 语言运行时 | 成功/失败 缺:____ | __s | |
| 2 | | 包管理器 | 成功/失败 | __s | |
| 3 | | CLI 工具 | 成功/失败 缺:____ | __s | |

## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)
