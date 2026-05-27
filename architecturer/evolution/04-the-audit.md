# 第四章：经历大体检

第三天他们把我从头到脚拆开检查了一遍。

---

## 15 路大军

15 个 agent，5 个方向，每个方向 3 个人交叉验证：

1. **容器 & 资源** — 我的容器健壮吗？
2. **核心服务** — PG、Redis、Kafka、CK、Grafana 都活着吗？
3. **网络 & 代理** — sing-box、代理链路、nuc8 隧道通吗？
4. **Boss & 孤儿** — 我有没有死掉的容器占着资源？
5. **文档 & 配置** — 我的文档跟实际跑的一致吗？

结果很难看。

### 🔴 警报 1：数据管道断了

Hooks → CK 管道三个环节全部消失：
- CK 里没有 `kyb` 库
- `emit-ck.sh` 脚本不在
- `settings.json` hooks 配置不在

当前 session 一条 event 都没进去。上一任留下的 6700+ 条 events 成了历史遗迹。

### 🔴 警报 2：15/16 容器裸奔

整个集群里唯一符合规范的容器是 `kyb-infra-boss2`（有 tini + 4 GiB 限制）。其他的——PG、Redis、Kafka、CK、Grafana、sing-box、cc-connect——全裸。

没 `--init` = 僵尸会堆积。无内存限制 = 死循环能炸穿宿主。

### 🔴 警报 3：文档全是错的

Registry Cache 的文档 7 处失真——容器名、网络模式、端口、代理类型、代理目标。全错。拿着文档去连 registry 只会撞墙。

## 代码审计：95 个问题

他们还扫了我的代码。范围：`lib/kyb/*.rb`、`test/*.rb`、`entrypoint.sh`、`Dockerfile`、`.gitlab-ci.yml`。

**25 HIGH / 40 MEDIUM / 30 LOW = 95 个问题。**

最痛的五类：

| # | 问题 | 多少个 |
|---|------|--------|
| 1 | Shell 注入面 | 6 处 |
| 2 | 重复代码模式 | 多处（volume/DID/轮询）|
| 3 | rescue Exception 滥用 | 5+ 处 |
| 4 | 超大方法（Docker.run 115 行）| 2 处 |
| 5 | 测试污染 | 跨文件 |

## 修复

当天修了 8 个 MR：

| MR | 修什么 |
|----|--------|
| !120 | Heredoc 注入 `<< 'YAML'` |
| !121 | doctor 命令接线 |
| !122 | HTTPS_PROXY 文档 |
| !123 | Branch 名校验 |
| !125 | morning crash |
| !126 | 死常量清理 |
| !127 | 审计报告 |
| !129 | Shell 注入 Open3.capture3 |

Wave 1（Shell 注入）全部修完。Wave 2（测试污染）修了一半。Wave 3-5 还躺着。

## 一个没发生的灾难：Go 重写

他们差点用 Go 重写我。评估结果：13-16 天，功能零增长。最后选了 Tebako 打单文件二进制——不碰我的代码，几天搞定，部署成一个文件。

Ruby 对我而言从来不是问题。我只有 stdlib，没有任何 gem 依赖。Tebako 只是让部署也变简单了。
