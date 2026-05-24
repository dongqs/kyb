# Safety + Tunnel Day — 2026-05-24

> 两天内第二个 infra-boss。上一任死于自删实验，这一任补安全网 + 修 nuc8 隧道。

---

## 上午：docker.sock 权限收紧

**问题：** 所有 kyb 容器 RW 挂载 docker.sock，任何容器都能 `docker rm -f kyb-infra-boss`。
上一任的 entrypoint.sh wrapper（MR !170）只防了交互式 shell，`docker exec` 绕过。

**改动：** 默认不挂载 docker.sock，`kyb create --docker` 显式启用，或项目配置 `docker_sock: true`。

| 场景 | docker.sock |
|------|-------------|
| `kyb create proj-feat` | ❌ 无 |
| `kyb create proj-feat --docker` | ✅ 有 |
| `kyb infra up` | ✅ 有（不变） |
| `kyb did create` | ✅ 有（不变） |

**文件：** `lib/kyb/{docker,config,cli}.rb`, `lib/kyb/cli/create.rb`, `test/test_docker.rb`

## 下午：nuc8 隧道重建

**问题：** 上一任把 SSH `-D 2081` 隧道开在自己容器里，容器一删隧道就死。
所有 `leyantech.com` 流量经 sing-box nuc8-proxy 出站，nuc8 不可达 → SOCKS 断连。

**修复链路：**
```
curl → sing-box (nuc8-proxy) → kyb-infra-nuc8-tunnel (SSH -D :2081) → nuc8 → git.leyantech.com ✅
```

**新建 `kyb-infra-nuc8-tunnel`：**
- `restart: always` — 不依赖 boss 容器生命周期
- `kyb-base:latest` 镜像，`ssh -D 0.0.0.0:2081 -N dongqs@100.98.29.39`
- 挂载宿主机 `.ssh`，走 Tailscale 直连 nuc8

**发现：** sing-box 配置用的是 Docker 命名卷 `sb-config-v2`，不是直接宿主机路径。
之前写入 `~/.config/sing-box/` 的文件没有生效——浪费了半小时 debug。

**还缺的：**
- `.kyb-net` DNS 在 sing-box 里没调通，nuc8-proxy 用静态 IP
- `sb-config-v2` 卷的内容没有同步到宿主机 git 仓库
- nuc8 原生 SOCKS5（dante-server）需要宿主机 sudo，还没装

## 教训

1. **关键网络隧道不能挂在 ephemeral 容器里** — 必须 `restart: always`
2. **改配置前先确认挂载方式** — 命名卷 vs 宿主机路径，搞错了等于没写
3. **不拿自己做实验** — 验证安全措施要用外部视角，不是亲自下场

## 文档产出

- `docs/infra/nuc8-tunnel-architecture.md`（新建）
- `npc/kyb-infra-boss.md`（更新拓扑 + 铁律 6）
- `docs/infra/infra-boss-safety-design.md`（补充隧道原则）
- `docs/infra/NEW-BOSS-QUICK-REF.md`（更新容器列表）

## MR

MR 包含今天两个改动：docker.sock 权限收紧 + nuc8 隧道重建 + 铁律 6 + 全部文档。
