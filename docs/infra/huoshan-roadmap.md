# 火山云 Infra-Boss 路线图

> 目标：将 kyb 基础设施从 macOS 本地（OrbStack）迁移至火山云 ECS。
> 这是 kyb 项目上云的第一步，实现多云架构（Mac ↔ 火山云 ↔ 阿里云）。

---

## 前置教训（2026-05-24~25 积累）

过去 30 小时（2026-05-24 22:00 ~ 2026-05-25 04:00）在 Mac 本地基础设施中积累的关键教训，
**_这些教训在火山云 ECS 部署时必须同步考虑_**，否则会重复踩坑。

### L1. IP 漂移坑 — 容器重建后 IP 会变，sing-box 配置要同步更新

**现象：** `kyb-infra-nuc8-tunnel` 容器重建后，`kyb-net` 分配的 IP 地址可能变化
（例如从 `192.168.97.3` 变为其他地址）。sing-box 的 `nuc8-proxy` outbound 中配的是
静态 IP，忘记同步更新就会导致 GitLab 访问中断。

**影响：** 所有走 `nuc8-proxy` 出站的流量（GitLab、公司内网）全部 403/超时。

**解决方案：**
- 容器重建后立即 `docker inspect <container> | jq '.[0].NetworkSettings.Networks.<network>.IPAddress'`
- 同步更新 sing-box `config.json` 中的 `server` 地址
- 或者使用 Docker DNS（容器名解析）而非静态 IP，但 sing-box `system-dns` 不能解析 `.kyb-net` 主机名
- **火山云上：** 使用固定 IP / 弹性网卡，或容器编排（Docker Compose / K3s）自动 DNS 发现

**相关文档：** `docs/infra/infra-boss-safety-design.md` 教训 13.2

### L2. sing-box 不能加内存限制（启动峰值 OOM）

**现象：** 给 sing-box 容器加 `--memory 256m` 限制后，Mac 重启时所有服务并发连接，
sing-box 启动峰值超过 256m 导致 OOM，全集群断网。

**根因：** sing-box 启动时需要加载路由规则、检测所有出站代理（relay）状态，
高峰期内存使用可达 300~500m。

**解决方案：**
- **不对 sing-box 设内存限制**，或至少给 512m+
- 运行时稳定后内存使用很低（~80m），但启动峰值必须留够余量
- **火山云上：** ECS 内存充裕（4C8G+），sing-box 无需限制，但要注意其他容器的内存分配

**相关文档：** `docs/network/sing-box.md`、`docs/infra/handbook/sing-box-deploy.md`、
commit `0e0e1a1` / `86dc788`

### L3. NO_PROXY 不要包含 .leyantech.com（否则 nuc8 隧道白走）

**现象：** `Kyb::Config::DEFAULT_NO_PROXY` 曾包含 `.leyantech.com`，导致 GitLab 流量
绕过 sing-box/nuc8 隧道直连，被 IP 白名单拦住返回 403。

**影响链：**
```
容器 ALL_PROXY + NO_PROXY=.leyantech.com
  → curl/glab 看到 .leyantech.com 在 NO_PROXY → 直连
  → GitLab IP 白名单拦住 → 403
  → 用户以为是代理/SSH 坏了
  → 调试方向完全跑偏
```

**解决方案：**
- `.leyantech.com` 不能出现在 NO_PROXY 中（除非明确知道哪些子域名直连）
- NO_PROXY 只应包含内部地址（`localhost`、`127.0.0.1`、`host.orb.internal`、Docker 网段等）
- 路由决策由 sing-box 做（IP 级别），NO_PROXY 不参与域名路由
- **火山云上：** 同样要注意 —— 如果火山云 ECS 需要通过 nuc8 隧道访问公司内网，
  `.leyantech.com` 绝不能进 NO_PROXY

**相关文档：** `docs/network/proxy.md`、`docs/infra/infra-boss-safety-design.md` 教训 9 & 11、
commit `0c770d1` / `bc5cd28`

### L4. nuc8 隧道要等 SSH 稳定了再启动

**现象：** 隧道容器（`kyb-infra-nuc8-tunnel`）启动时 SSH 连接还没建立，
`ssh -D` 命令失败退出，`restart: always` 不断重试但一直失败（如果 SSH key 或网络有问题）。

**影响：** GitLab 在公司内网不可达，所有依赖 nuc8 出站的流量中断。

**解决方案：**
- 隧道容器启动后加 `HEALTHCHECK`，检测 SSH 进程和 2081 端口
- entrypoint.sh 中先测试 SSH 连通性再建立隧道
- 使用 `autossh` 替代原生 `ssh -D`（自动重连）
- **火山云上：** 如果从火山云连 nuc8 也需要 SSH 隧道，同样需要 HEALTHCHECK + 重试

**相关文档：** `docs/infra/nuc8-tunnel-architecture.md`、`docs/infra/handbook/nuc8-tunnel-deploy.md`

### L5. 启动锁设计（issue #170）需要在云上同样实现

**设计：** kyb 启动锁（`Kyb::StartupLock`）防止 CLI 被意外执行。设计方案（Round 3）
采用方案 A'（交互式同意 + env bypass），有 5 级检查链：
1. `.consent` 文件内容校验
2. `KYB_STARTUP_BYPASS=true` 环境变量
3. 非 TTY 自动跳过
4. config.yml `startup_lock.enabled: false`
5. 交互式提示

**云上需求：**
- 火山云 ECS 上的 kyb 也需要同样的启动锁
- CI/CD 环境应配置 `KYB_STARTUP_BYPASS=true`
- `.consent` 文件位置可能需要调整（云上 home 目录可能不同）
- **所有容器（包括云上）共用一个启动锁策略**

**相关文档：** `docs/infra/designs/kyb-startup-lock.md`、issue #170

### L6. 容器分层（issue #173）— agent 和服务容器分开网络

**设计：** 将容器分为三层，不同生命周期和重启策略：
- **服务层（service）：** `restart: always`，与 agent 生命周期解耦
  - sing-box（网络代理）
  - nuc8-tunnel（SSH 隧道）
  - ClickHouse / Grafana / Redis / Kafka（可观测性）
- **Agent 层（agent）：** `restart: unless-stopped`，随用随建
  - infra-boss（基础设施管理）
  - chat / architecturer（Claude 会话）
- **Sandbox 层（sandbox）：** 临时，用完即删
  - 开发容器、测试容器

**云上需求：**
- 火山云 ECS 上同样采用三层架构
- 服务容器绑固定 IP 或使用 Docker 网络别名
- Agent 容器通过 Docker DNS 发现服务
- 可以使用 Docker Compose 管理服务容器组

**相关文档：** `docs/infra/designs/` 相关设计、issue #173

### L7. 三体架构（issue #176）— explorer/worker/elder 三层

**设计：** agent 群体采用三层架构：
- **Explorer（探索者）：** 前沿实验、新方案验证，最多 3 个并行
- **Worker（工人）：** 执行具体任务，按需创建，可批量（3~6~N 扩展）
- **Elder（长老）：** 代码审查、设计评审，高 context 投入

**云上需求：**
- 火山云 ECS 运行 Worker 和 Explorer
- Elder 留在 Mac 本地（低延迟访问设计文档和代码库？或也上云）
- Worker 按需创建/销毁，利用云上弹性
- 三体的通信不依赖 Mac 本地网络

**相关文档：** `docs/infra/stories/`、issue #176

---

## 阶段 0：账号与环境

- [ ] 注册火山云账号，开通 ECS + VPC + 安全组服务
- [ ] 使用 AccessKey 对接火山云 API（参考下方 API 操作步骤）
- [ ] 创建 VPC + 子网 + 安全组
- [ ] 从 Mac 端/容器能通过 API 管理火山云资源
- [ ] 验证：`volcengine-python-sdk` 能正常调用 API

### 火山云 API 操作步骤

使用 AccessKey 调用火山云 API（Python SDK `volcengine-python-sdk`）：

#### 0.1 准备凭据

```python
# 从 .env 读取
ACCESS_KEY_ID = os.getenv('AccessKeyID')
SECRET_ACCESS_KEY = os.getenv('SecretAccessKey')

# 火山云区域
REGION = 'cn-shanghai'  # 或其他可用区
```

```bash
# 代理（sing-box SOCKS5）
export HTTPS_PROXY=socks5://kyb-infra-sing-box:2080
```

## 网段检查（必做）

创建 VPC 前必须确认 CIDR 不冲突：

| 网络 | CIDR | 说明 |
|------|------|------|
| 火山云新 VPC | 10.1.0.0/16（建议） | 本篇规划 |
| 阿里云 | 10.23.0.0/16 | 上次冲突死的 |
| 办公室网络 | 依赖具体配置 | 需人工确认 |
| Tailscale | 100.64.0.0/10 | 路由穿透 |

上次因为 CIDR 和阿里云撞了，整台机器变孤儿。

#### 0.2 创建 VPC

```python
from volcengine_ecs import EcsClient
from volcengine_vpc import VpcClient

vpc_client = VpcClient(
    region=REGION,
    access_key_id=ACCESS_KEY_ID,
    secret_access_key=SECRET_ACCESS_KEY
)

# 创建 VPC
vpc = vpc_client.create_vpc(
    vpc_name='kyb-infra',
    cidr_block='10.1.0.0/16'
)

# 创建子网
subnet = vpc_client.create_subnet(
    vpc_id=vpc['vpc_id'],
    cidr_block='10.1.1.0/24',
    subnet_name='kyb-infra-subnet'
)

# 创建安全组
sg = vpc_client.create_security_group(
    vpc_id=vpc['vpc_id'],
    security_group_name='kyb-infra-sg'
)

# 安全组规则：SSH、Docker 通信、ICMP
vpc_client.authorize_security_group_ingress(
    security_group_id=sg['security_group_id'],
    rules=[
        {'protocol': 'tcp', 'port': 22, 'cidr': '0.0.0.0/0'},        # SSH
        {'protocol': 'tcp', 'port': 2375, 'cidr': '10.1.0.0/16'},   # Docker API
        {'protocol': 'tcp', 'port': 2080, 'cidr': '0.0.0.0/0'},     # sing-box
        {'protocol': 'tcp', 'port': 3000, 'cidr': '0.0.0.0/0'},     # Grafana
        {'protocol': 'icmp', 'cidr': '0.0.0.0/0'},                   # ping
    ]
)
```

#### 0.3 创建 ECS 实例

```python
ecs_client = EcsClient(
    region=REGION,
    access_key_id=ACCESS_KEY_ID,
    secret_access_key=SECRET_ACCESS_KEY
)

# 推荐配置：4C8G + Ubuntu 22.04
instance = ecs_client.create_instance(
    image_id='ubuntu_22_04_x64_20G_alibase_2024...',  # 火山云镜像 ID
    instance_type='ecs.g3.large',        # 4C8G（通用型）
    security_group_id=sg['security_group_id'],
    subnet_id=subnet['subnet_id'],
    instance_name='kyb-infra',
    description='kyb infrastructure host',
    allocate_public_ip=True,              # 分配公网 IP
    unique_suffix=False,
    eip_bandwidth=100,                    # Mbps
)
```

**流量路径验证：**
```
Mac/容器 → HTTPS_PROXY → sing-box:2080 → relay-JP1 → 火山云 API
                                                      ↓
Mac/容器 → SSH → 火山云 ECS 公网 IP:22 → docker exec
```

### 0.4 Tailscale 接入

火山云 ECS 加入 Tailscale 网络，实现跨云直连。

```bash
# 安装 Tailscale
curl -fsSL https://tailscale.com/install.sh | bash

# 认证并加入网络（需要 Tailscale 官网认证链接）
sudo tailscale up --advertise-routes=10.1.0.0/16
# --advertise-routes：将火山云 VPC 网段广播到 Tailscale 网络
# 这样 Mac 端可以通过 Tailscale 直连 ECS 内的容器

# 验证状态
tailscale status
```

**配置要点：**
- 在 [Tailscale 控制台](https://login.tailscale.com) 开启子网路由（Subnet Routes）
- Mac 端需执行 `tailscale up --accept-routes` 以接收火山云路由
- 阿里云 ECS 同样加入 Tailscale 后自动互通
- Tailscale 直连可作为 sing-box 的一个 outbound，实现多云 failover（参考阶段 2 方案 B）

---

## 阶段 1：基础设施部署（1-2 周）

- [ ] 在 ECS 上安装 Docker Engine
- [ ] 部署 sing-box 容器（注意 **L1/L2**：IP 漂移 + 内存限制）
- [ ] 部署 nuc8-tunnel 容器（注意 **L4**：SSH 稳定再启动）
- [ ] 部署 CK（ClickHouse）用于可观测性
- [ ] 部署 infra-boss（注意 **L5**：启动锁 / **L6**：容器分层）
- [ ] 配置网络链路：Mac ↔ 火山云 ↔ 阿里云
- [ ] 验证：从火山云 infra-boss 能访问 GitLab / GitHub / DeepSeek API

### 1.1 ECS 初始化脚本

```bash
# ECS 初始化脚本（cloud-init / 手动执行）

# 安装 Docker
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# 创建 Docker 网络
docker network create kyb-net --subnet 10.1.2.0/24
# 注意 L1：容器 IP 漂移，kyb-net 上服务容器用固定 IP 或别名

# 创建数据目录
mkdir -p /data/kyb/{sing-box,nuc8-tunnel,clickhouse,postgresql,redis}

# 配置系统参数
cat >> /etc/sysctl.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p
```

### 1.2 部署顺序（依赖链）

```
sing-box（基础网络）→ nuc8-tunnel（公司内网）→ 可观测性 → infra-boss → sandbox
   ↓                    ↓
网络出口           GitLab 可达
```

> **注意：** 这个顺序和 Mac 本地的一致。先起 sing-box（全集群代理入口），
> 等 SSH 稳定后起 nuc8-tunnel，验证 GitLab 可达后再起其他（**参考 L4**）。

### 1.3 网络验证清单

```bash
# 1. 公网可达
curl -sI https://github.com

# 2. 火山云 API 可用
python3 -c "from volcengine_ecs import EcsClient; print('OK')"

# 3. sing-box 代理工作（从同网络容器）
HTTPS_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://github.com

# 4. GitLab 可达（通过 nuc8 隧道，注意 L3）
HTTPS_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://git.leyantech.com

# 5. DeepSeek API 可达
HTTPS_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://api.deepseek.com

# 6. 容器间 DNS 解析
docker exec kyb-infra-boss ping -c 1 kyb-infra-sing-box
```

---

## 阶段 2：灰度切换（1-2 周）

- [ ] 把 1-2 个开发容器迁到火山云
- [ ] 验证延迟和稳定性
- [ ] 测试多云互备（火山云挂了自动切回 Mac）
- [ ] 注意 **L7**：三体架构中 worker 放云上，elder 留 Mac 本地

### 流量切换策略

**方案 A — 多云 sing-box：**
- Mac 本地 sing-box 和火山云 sing-box 各自独立
- 通过 `urltest` 或 `fallback` 出站类型实现故障切换
- Mac sing-box 出站包含一个 `volcano-direct` 路径（VPN/SSH 隧道到火山云）

**方案 B — 统一网络：**
- 火山云 ECS 加入 Tailscale 网络
- 所有跨云流量走 Tailscale 直连
- 火山云容器通过 Tailscale 访问 Mac 本地服务

---

## 阶段 3：生产就绪（持续）

- [ ] 监控告警（CK + Grafana）
- [ ] 成本追踪（火山云计费 API）
- [ ] 自动扩容（按需创建 ECS + 部署容器）
- [ ] 多云互备自动化

---

## 参考文档

| 文档 | 内容 |
|------|------|
| `docs/infra/designs/kyb-startup-lock.md` | 启动锁设计（issue #170） |
| `docs/infra/infra-boss-safety-design.md` | 防自杀机制 + 13 条教训 |
| `docs/infra/nuc8-tunnel-architecture.md` | nuc8 隧道架构 |
| `docs/infra/handbook/sing-box-deploy.md` | sing-box 部署手册 |
| `docs/infra/handbook/nuc8-tunnel-deploy.md` | nuc8 隧道部署手册 |
| `docs/network/proxy.md` | 代理配置 + NO_PROXY |
| `docs/network/sing-box.md` | 网络拓扑与路由 |
| `docs/infra/handbook/clickhouse-deploy.md` | CK 部署 |

## 踩坑备忘录（Cloud 专用）

| # | 预测问题 | 预防措施 |
|---|---------|---------|
| 1 | 火山云 API 限频 | 请求加退避重试，batch 操作间隔 200ms |
| 2 | ECS 公网 IP 变化 | 用弹性公网 IP（EIP），不依赖实例关联的公网 IP |
| 3 | 安全组规则忘了 | 部署前写好完整规则集，用 IaC 管理 |
| 4 | 容器间通信跨宿主机 | 初期单机部署，后期考虑 Docker Swarm / K3s |
| 5 | 火山云到 GitLab 延迟 | 新加坡/日本 region 可能更快，实测后决定 |

---

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-05-24 | 初版 — 基础路线图 |
| 2026-05-26 | 更新 — 加入 7 条教训 + 火山云 API 操作步骤 + 部署顺序 + 网络验证清单 |
| 2026-05-25 | 更新 — region 改为 cn-shanghai + 加入网段检查 + Tailscale 接入说明 + CIDR 统一为 10.1.0.0/16 |

／人◕ ‿‿ ◕人＼
