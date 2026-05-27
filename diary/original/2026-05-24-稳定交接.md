# 稳定交接 — 2026-05-24

前三天（5/22-5/24）解决了导致基础设施反复扑腾的根因。以后回来的人不用再踩一遍。

---

## 已消灭的波动源

### 1. nuc8 隧道（已死因：SSH 隧道随容器销毁丢失）

**症状：** `git.leyantech.com` 不可达，nuc8-proxy 路由到死 IP。

**修复：**
- `entrypoint.sh` 新增 infra-boss 启动逻辑：安装 autossh、建隧道 boss → nuc8（Tailscale 直连，不再经 sim）
- 容器活着时 autossh 自动保活，断线重连
- 容器重建后 entrypoint 自动重建隧道

**验证命令：**
```bash
docker exec kyb-infra-boss ss -tlnp | grep 2081  # 隧道应在监听
docker exec kyb-infra-boss curl -sx socks5://127.0.0.1:2081 https://git.leyantech.com
```

### 2. sing-box 端口映射（已死因：重建容器丢了 `-p 2080:2080`）

**症状：** 宿主机上 `127.0.0.1:2080` 没人监听，所有走代理的请求断掉。

**修复：**
- `kyb-infra-sing-box` 重建时明确加 `-p 2080:2080` 和 `--network kyb-net`
- 现在宿主机 `127.0.0.1:2080` → 容器 `2080` 通了

**验证命令：**
```bash
curl -x socks5://127.0.0.1:2080 https://github.com   # 从 macOS 宿主机跑
curl -x socks5://host.orb.internal:2080 https://github.com  # 从容器的跑
```

### 3. sing-box 容器网络隔离（已死因：重建容器落到默认 bridge 网）

**症状：** `kyb-infra-sing-box` 落在 `192.168.215.x`，其他容器在 `kyb-net` 的 `192.168.97.x`。容器名 DNS 不通。

**修复：** 重建时加 `--network kyb-net`，与其他容器同网段。

### 4. sing-box 配置只读 volume（已死因：`sb-config-v2` volume 的 config.json 指向死的 .17）

**症状：** nuc8-proxy server 写着 `192.168.97.17`（不存在的 IP）。

**修复：** 从宿主机只读 mount 读配置，改 nuc8-proxy server 为 `192.168.97.3`，
写回 `sb-config-v2` volume，SIGHUP 重载。

**下次改配置的方法：**
```bash
# 不改 volume（容器重建会丢），改宿主机配置
cd ~/.config/sing-box
vim config.json
sing-box check -c config.json
cp config.json config.json.last-good
docker kill -s HUP kyb-infra-sing-box  # 或重启容器
```

---

## 当前稳定状态

| 服务 | 健康 | 依赖 |
|------|------|------|
| `kyb-infra-sing-box` | ✅ restart: always，有端口映射，在 kyb-net | 无 |
| `kyb-infra-boss` | ✅ 随用随建，auto-recovery | sing-box（代理）|
| nuc8 隧道 | ✅ autossh 保活 | sim 在线、nuc8 在线 |
| GitLab | ✅ 全链路通 | sing-box → nuc8 隧道 |
| 宿主机代理 | ✅ `127.0.0.1:2080` → sing-box 容器 | sing-box 容器运行中 |

---

## 已知未修复

1. **`entrypoint.sh` 改 sing-box 配置** — 当前通过 volume 写配置，但 entrypoint 里没有自动修 .17→.3 的逻辑。如果下次容器重建后 sing-box 配置又指向了不存在的 IP，entrypoint 不会自动修。
2. **`NO_PROXY` 未设置** — 所有容器都缺 `NO_PROXY`，全部流量走代理有潜在性能损失。
3. **`--init` 未加** — 所有容器缺 `--init` 参数，僵尸进程可能堆积。
4. **无内存限制** — 所有容器吃满 15.65G。

---

## 平稳运行检查清单

```bash
# 1. 容器都在
docker ps --filter name=kyb-infra

# 2. 代理通
curl -x socks5://127.0.0.1:2080 -sI https://github.com
curl -x socks5://127.0.0.1:2080 -sI https://git.leyantech.com

# 3. 隧道在
docker exec kyb-infra-boss ss -tlnp | grep 2081

# 4. GitLab API 通
docker exec kyb-infra-boss curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  https://git.leyantech.com/api/v4/version

# 5. 磁盘够
df -h /
```

---

*2026-05-24 | kyb-infra-boss*
