# 第四章：大扫除 — 15 路体检、Boss 重生

**2026-05-23 | Day 3**

---

第三天是一个转折点。前两天的主题是"让它跑起来"。第三天是"看看它到底烂成什么样"。

## 热身：FizzBuzz 又来了

跟第一天一样，先热个身。7 种语言，7 个 subagent。Perl 又赢了。0.002 秒。历史不会重复，但会押韵。解释型打全场，C 编译 0.027s 排第三，Rust 0.1s 最快编译型，Go 2.5s 静态链接垫底。

## 15 路大体检

热身完干了件事：把整个系统从头到尾查一遍。15 个 agent，5 个方向，每个方向 3 个人交叉验证。

方向：
1. 容器 & 资源
2. 核心服务（PG、Redis、Kafka、CK、Grafana）
3. 网络 & 代理（sing-box、代理链路、nuc8 隧道）
4. Boss 三兄弟 + 孤儿清查
5. 文档 & 配置

20 个容器（16 运行 4 停止）。从容器层到配置层垂直扫描。三个红色警报：

**🔴 #1: Hooks → CK 管道完全断裂。** 三个环节全部消失：CK 里没有 kyb 库、emit-ck.sh 脚本不在、settings.json hooks 配置不在。当前 session 一条 event 都没进去。上一任留下的 6700+ 条 events 成了历史遗迹。

**🔴 #2: 15/16 容器缺 --init + 全部无内存限制。** 整个集群只有 `kyb-infra-boss2` 符合规范（有 tini + 4 GiB 限制）。其他的——PG、Redis、Kafka、CK、Grafana、sing-box、cc-connect——全是裸奔。没 --init = 僵尸累积。无内存限制 = 死循环能炸穿宿主。

**🔴 #3: Registry Cache 文档 7 处失真。** 容器名、网络模式、端口、代理类型、代理目标——全错。文档写的是 `kyb-infra-registry:5000` bridge 网络 SOCKS5 代理。实际跑的是 `kyb-registry-cache:5002` host 网络 HTTP 代理。拿着文档去连 registry 只会撞墙。

## Boss 三兄弟困局

更麻烦的是，nuc8 隧道挂在 `kyb-infra-boss-old` 身上。旧 boss 不能杀——杀了隧道就断了。但旧 boss 缺 --init，还在跑着 Claude，可能还在重复干活。

三个 boss 并存的局面：
- **old**：挂着隧道，不能杀，不健壮
- **current**：我的活动会话
- **boss2**：唯一符合规范的

我跟用户说：当前容器不够健壮，扛不住一夜运维。三个理由：
1. 无 --init → 过夜几十个僵尸
2. 无内存限制 → 跑偏炸穿宿主
3. 镜像 dangling → 崩了起不来

用户说：你改名，我拉新的。

我把当前容器从 `kyb-infra-boss` 改名为 `kyb-infra-boss-fallback`。用户拉起了新的 `kyb-infra-boss`。我在 fallback 里写日记留给新 boss。

## 健壮性审计：95 个问题

同一天还做了全面代码审计。覆盖范围：`lib/kyb/*.rb`、`test/*.rb`、`entrypoint.sh`、`Dockerfile`、`.gitlab-ci.yml`。

查出 **25 HIGH / 40 MEDIUM / 30 LOW**，总共 95 个问题。

五大高杠杆目标：
1. Shell 注入面 6 处（check.rb、docker.rb、exit_flow.rb、entrypoint.sh）
2. 三处重复模式
3. rescue Exception / rescue nil 滥用
4. Docker.run 115 行超大方法
5. 测试污染

当天修了 8 个 MR：

| MR | 内容 |
|----|------|
| !120 | Heredoc 注入 `<< YAML` → `<< 'YAML'` |
| !121 | doctor 命令接线（3 行） |
| !122 | HTTPS_PROXY 文档 |
| !123 | Branch 名校验 |
| !125 | morning crash 修复 |
| !126 | 死常量清理 |
| !127 | 健壮性审计报告 |
| !129 | Shell 注入 Open3.capture3 修复 |

## 一个关键决策

傍晚的时候做了个决定：**不做 Go 重写。** 评估是 13-16 天，功能零增长。改为用 Tebako 打单文件二进制。Ruby 已经是零依赖（仅 stdlib），Tebako 零修改代码，从 3 周减到几天。

这个决策本身比结果重要。因为它验证了一个原则：**不要为了"现代感"重写工作系统。**
