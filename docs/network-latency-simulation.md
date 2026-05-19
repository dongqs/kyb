# 网络延迟模拟与性能压测

kyb DID 容器内应用与 PostgreSQL 同机部署（localhost），网络延迟近乎为 0。但这掩盖了生产环境中网络 RTT 对性能的真实影响。本文档记录如何模拟网络延迟、以及延迟在不同配置下的实测影响。

## 模拟方法

### 方案对比

| 方案 | 精度 | 开销 | 权限要求 | 适用场景 |
|------|------|------|---------|---------|
| `tc netem`（内核级） | 高（µs 级） | 低 | `NET_ADMIN` | 最推荐，需容器加 capability |
| TCP proxy（用户态） | 中（受 asyncio 影响） | 中（~40% proxy overhead） | 无 | 无特权容器可用 |
| eBPF | 高 | 低 | `BPF` | 最精准但配置复杂 |

### TCP Proxy 方案（本文采用）

Python asyncio 代理，在应用和 PG 之间插入可控延迟：

```
应用 (:8081) → proxy (:15432) → [delay] → PostgreSQL (:5432)
```

使用方式见下方。

## 使用方式

在 DID 容器内启动：

```bash
# 启动 proxy，0.5ms 单向延迟（1ms RTT）
python3 /tmp/pg_proxy.py 15432 5432 0.5

# 启动应用时 JDBC URL 指向 proxy 端口
QUARKUS_DATASOURCE_JDBC_URL="jdbc:postgresql://127.0.0.1:15432/hamilton_dev"
```

延迟参数 = 单向延迟 ms，双向各加一次，RTT = 2 × 参数。

## Hamilton 压测结果

> Hamilton 项目有持续更新的整合文档：[benchmarks.md](https://git.leyantech.com/training/hamilton/-/blob/master/docs/benchmarks.md)（性能汇总）、[full-chain.md](https://git.leyantech.com/training/hamilton/-/blob/master/docs/full-chain.md)（全链路分析）。本文数据为特定版本快照，最新数据请参考 Hamilton 项目文档。

### 环境

| 项目 | 值 |
|------|-----|
| 应用 | Hamilton (Quarkus 3.28.1 + Kotlin) |
| 数据库 | PostgreSQL 16（同机 localhost） |
| 容器 | DID 容器，10 核无限制 |
| 压测工具 | Apache Bench (ab) |
| 测试端点 | `GET /api/sellers/42/trades/{tid}/seller_orders` |
| 数据量 | 1 seller + 10K seller_orders |

### CPU 核数影响

#### Health endpoint（纯 CPU，无 DB）

| 核数 | RPS | 相对 1 核加速比 |
|------|-----|---------------|
| 1 | 4,117 | 1.0x |
| 2 | 12,083 | 2.9x |
| 4 | 21,468 | 5.2x |
| 8 | 28,907 | 7.0x |
| 10(∞) | 30,227 | 7.3x |

纯 CPU 路径近线性扩展到 4 核，之后受 vert.x event loop 上限约束。

#### DB 查询（max-size=1）

| 核数 | c=10 | c=50 | c=100 |
|------|------|------|-------|
| 1 | 892 | 893 | 864 |
| 2 | 1,810 | 1,775 | 1,784 |
| 4 | 1,850 | 1,903 | 1,877 |
| 8 | 1,853 | 1,754 | 1,690 |
| 10 | 1,915 | 1,588 | 1,721 |

2 核后封顶，瓶颈在 JDBC 连接池。

### 网络延迟 + 连接池组合影响

#### max-size=1（默认）

| 延迟 | c=10 | c=50 | c=100 |
|------|------|------|-------|
| 0ms（直连） | 1,914 | 1,588 | 1,721 |
| 0.5ms（proxy，1ms RTT） | 126 | 126 | 124 |

**1ms RTT 导致吞吐暴跌 15x**。单连接串行处理，每请求额外等 1ms 网络往返，吞吐上限 = 1000ms / (查询耗时 + 1ms)。

#### max-size=20（合理配置）

| 延迟 | c=10 | c=50 | c=100 | P50 | P99 |
|------|------|------|-------|-----|-----|
| 0ms（直连） | — | 2,202 | 6,624 | 7ms | 20ms |
| 0ms（proxy，纯 overhead） | — | 2,616 | 3,220 | 15ms | 35ms |
| 0.5ms（proxy，1ms RTT） | 882 | 3,020 | 3,126 | 12ms | 34ms |

连接池从 1 放大到 20 后，延迟影响从 15x 降低到了约 2x（对比直连 6,624 vs 延迟 3,126）。并发请求不排队等连接，网络延迟的影响被均摊。

### 关键结论

1. **延迟 + 小连接池 = 灾难**：单连接池下 1ms RTT 让吞吐降 15 倍
2. **连接池是对抗延迟的第一道防线**：max-size=20 后延迟影响大幅降低
3. **CPU 不是 DB 查询瓶颈**：DB 查询路径 2 核就封顶，更多核只对纯 CPU 路径有帮助
4. **本地压测必须模拟延迟**：0.2ms 的 localhost 延迟和 0.5-2ms 的同机房/跨可用区延迟有本质差异
5. **所有测试零失败请求**：系统在极限负载下行为优雅

### Proxy Overhead 说明

Python asyncio proxy 自身引入约 40% 开销。精确模拟应使用 `tc netem`（需 `NET_ADMIN` capability）：

```bash
# 在 DID 容器上精确模拟 0.5ms 单向延迟
docker run --cap-add=NET_ADMIN ...  # 创建时加权限
# 或对已有容器：
docker exec ... tc qdisc add dev lo root netem delay 500us
```

但 proxy 方案胜在零权限要求，定性验证足够。

## Native Image 场景

### Native vs JVM 核数效率

| 核数 | JVM DB RPS | Native DB RPS | JVM Health RPS | Native Health RPS |
|------|-----------|-------------|---------------|-----------------|
| 1 | 893 | **1,338** | **4,117** | 3,822 |
| 2 | 1,775 | **2,607** | **12,083** | 5,851 |
| 4 | **1,903** | 1,699 | **21,468** | 7,018 |
| 无限 | 3,020 | **4,984** | **30,227** | 20,395 |

### 选型结论

**Native → 1-2 核小实例，多而轻。** 串行 GC + 无 JIT，2 核后效率暴跌。4 核预算下 2台2核 或 4台1核 最优。

**JVM → 2-4 核实例，少而大。** JIT 优化热路径，纯 CPU 密集场景用大实例反超 Native。

> 更多 Native Image 编译和部署细节见 Hamilton 项目 [deployment-guide.md](https://git.leyantech.com/training/hamilton/-/blob/master/docs/deployment-guide.md)。

### 生产推荐

| 负载类型 | 运行时 | 实例规格 | 原因 |
|---------|--------|---------|------|
| DB 查询为主 | **Native** | **2 × 2核** 或 **4 × 1核** | DB 路径 Native 快 50-65% |
| 纯 CPU 密集 | **JVM** | **1 × 4核** | JIT 让 CPU 吞吐翻倍 |
| 混合 | **Native** | **2 × 2核** | 启动快、内存低、运维简单 |

## 批量压测脚本

```bash
#!/bin/bash
# cpu_bench.sh — 自动压测脚本
# Usage: cpu_bench.sh <cpus> <label>

CPUS=$1
LABEL=$2

cd /home/dev/projects/hamilton
export ORG_GRADLE_PROJECT_nexusUser=readonlyuser \
  ORG_GRADLE_PROJECT_nexusPassword=mimashishiliuwei \
  GRADLE_USER_HOME=.cache \
  QUARKUS_HTTP_HOST=0.0.0.0 \
  QUARKUS_HTTP_PORT=8081 \
  QUARKUS_DEV_SERVICES_ENABLED=false \
  QUARKUS_DATASOURCE_JDBC_URL="jdbc:postgresql://127.0.0.1:15432/hamilton_dev" \
  QUARKUS_DATASOURCE_USERNAME=postgres \
  QUARKUS_DATASOURCE_PASSWORD= \
  QUARKUS_DATASOURCE_JDBC_MAX_SIZE=20 \
  QUARKUS_OTEL_ENABLED=false

./gradlew quarkusDev --no-daemon --no-configuration-cache > /tmp/quarkus.log 2>&1 &
# wait for "Listening on" in log, then:
ab -n 5000 -c 50 "http://127.0.0.1:8081/api/sellers/42/trades/test-tid-5000/seller_orders?fields=oid,status,title,payment"
```

## TCP Proxy 源码

```python
"""TCP proxy with configurable latency for simulating network delay."""
import asyncio, sys

BUFFER_SIZE = 65536

class LatencyProxy:
    def __init__(self, listen_host, listen_port, target_host, target_port, delay_ms=1.0):
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.target_host = target_host
        self.target_port = target_port
        self.delay = delay_ms / 1000.0

    async def forward(self, src, dst, delay):
        try:
            while True:
                data = await asyncio.wait_for(src.read(BUFFER_SIZE), timeout=3600)
                if not data:
                    break
                if delay > 0:
                    await asyncio.sleep(delay)
                dst.write(data)
                await dst.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            try:
                dst.close()
            except:
                pass

    async def handle_client(self, reader, writer):
        try:
            target_reader, target_writer = await asyncio.wait_for(
                asyncio.open_connection(self.target_host, self.target_port), timeout=5.0)
        except Exception:
            writer.close()
            return
        task_a = asyncio.create_task(self.forward(reader, target_writer, self.delay))
        task_b = asyncio.create_task(self.forward(target_reader, writer, self.delay))
        done, pending = await asyncio.wait([task_a, task_b], return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()

    async def run(self):
        server = await asyncio.start_server(self.handle_client, self.listen_host, self.listen_port, backlog=4096)
        addr = server.sockets[0].getsockname()
        print(f"PG Proxy: {addr[0]}:{addr[1]} -> {self.target_host}:{self.target_port} [{self.delay*1000:.1f}ms delay]")
        async with server:
            await server.serve_forever()

if __name__ == "__main__":
    listen_port = int(sys.argv[1]) if len(sys.argv) > 1 else 15432
    target_port = int(sys.argv[2]) if len(sys.argv) > 2 else 5432
    delay_ms = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    asyncio.run(LatencyProxy("127.0.0.1", listen_port, "127.0.0.1", target_port, delay_ms).run())
```
