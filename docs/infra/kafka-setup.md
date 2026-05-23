# Kafka 容器化部署方案 — kyb-infra-kafka

> 2026-05-22
> 宿主机: Orbstack Docker on macOS, ARM64

## 决策: KRaft 模式 (无 Zookeeper)

**推荐方案**: 单容器 KRaft 模式，使用 `apache/kafka` 官方镜像。

KRaft (Kafka Raft) 模式自 Kafka 3.3+ 生产可用，3.5+ 稳定。优势:

- 无 Zookeeper 依赖 → 少维护一个容器
- 单节点部署更简单
- ARM64 镜像原生支持
- 资源占用更低 (省掉 ZK 的 JVM 开销)

## 前提条件

| 条件 | 状态 |
|------|------|
| Docker 运行中 | ✅ |
| 网络 `kyb-net` (192.168.97.0/24) | ✅ 已存在 |
| 代理 `kyb-infra-sing-box:2080` | ✅ 已存在 |
| 宿主机 macOS 无 Kafka 运行 | ✅ 确认 (端口 9092 空闲) |
| Kafka 镜像 | 需拉取 |

## Docker 镜像选择

### 首选: `apache/kafka:latest`

官方镜像，基于 Kafka 4.x，原生支持 KRaft，ARM64 多架构。

```bash
docker pull apache/kafka:latest
```

### 备选: `bitnami/kafka:latest`

Bitnami 镜像，KRaft 支持成熟，环境变量文档完善。如果官方镜像有问题可切换。

```bash
docker pull bitnami/kafka:latest
```

## Docker Run 命令

### 创建持久化卷

```bash
docker volume create kafka-data
```

### 启动容器

```bash
docker run -d \
  --name kyb-infra-kafka \
  --network kyb-net \
  --restart unless-stopped \
  -p 9092:9092 \
  -v kafka-data:/var/lib/kafka/data \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS="1@kyb-infra-kafka:9093" \
  -e KAFKA_LISTENERS="PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093" \
  -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kyb-infra-kafka:9092" \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_HEAP_OPTS="-Xmx512m -Xms512m" \
  -e KAFKA_BROKER_ID=1 \
  apache/kafka:latest
```

### 环境变量说明

| 变量 | 值 | 说明 |
|------|-----|------|
| `KAFKA_NODE_ID` | 1 | KRaft 节点 ID |
| `KAFKA_PROCESS_ROLES` | broker,controller | 单节点同时扮演 broker 和 controller |
| `KAFKA_CONTROLLER_QUORUM_VOTERS` | 1@kyb-infra-kafka:9093 | 单节点投票群组 |
| `KAFKA_LISTENERS` | PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093 | 内外部监听 |
| `KAFKA_ADVERTISED_LISTENERS` | PLAINTEXT://kyb-infra-kafka:9092 | 客户端连接地址 (DNS 名) |
| `KAFKA_HEAP_OPTS` | -Xmx512m -Xms512m | JVM 内存限制 (512MB) |
| `KAFKA_AUTO_CREATE_TOPICS_ENABLE` | true | 开发环境自动创建 topic |
| `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR` | 1 | 单节点必须设为 1 |
| `KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR` | 1 | 单节点必须设为 1 |
| `KAFKA_TRANSACTION_STATE_LOG_MIN_ISR` | 1 | 单节点必须设为 1 |

> **关于代理**: 容器内部 Kafka 组件之间通过 listener 通信 (`kyb-infra-kafka:9092` / `:9093`)，
> 不需要走代理。镜像拉取时可能会走 `docker.xuanyuan.me` mirror (已在 Docker daemon 配置中)。
> 容器运行时如果宿主机需要代理访问外网，参考 `kyb-infra-boss` 的 `ALL_PROXY` 配置，
> 但对于 Kafka 来说通常不需要 — 它不需要访问外网。

### 端口映射

| 端口 | 说明 |
|------|------|
| `9092:9092` | PLAINTEXT 客户端连接 (宿主机 → 容器) |
| `9093` | Controller 内部通信 (仅容器间，不映射到宿主机) |

宿主机上通过 `localhost:9092` 即可连接，容器内通过 `kyb-infra-kafka:9092` 连接。

## 生命周期管理

```bash
# 启动
docker start kyb-infra-kafka

# 停止
docker stop kyb-infra-kafka

# 重启
docker restart kyb-infra-kafka

# 日志
docker logs -f kyb-infra-kafka

# 删除 (保留数据卷)
docker rm -f kyb-infra-kafka

# 删除 (含数据卷)
docker rm -f kyb-infra-kafka
docker volume rm kafka-data
```

## 验证部署

### 1. 检查容器状态

```bash
docker ps --filter name=kyb-infra-kafka --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

预期输出:
```
NAMES              STATUS         PORTS
kyb-infra-kafka    Up 2 minutes   0.0.0.0:9092->9092/tcp
```

### 2. 检查容器日志 (确认 KRaft 启动成功)

```bash
docker logs kyb-infra-kafka 2>&1 | grep -E '(started|Kafka Server|started successfully)'
```

预期输出包含类似: `[KafkaServer] Started (kafka.server.KafkaServer)` 或 `started (kafka.server.Broker)`。

### 3. 从容器内验证 (推荐)

```bash
# 进入容器
docker exec -it kyb-infra-kafka bash

# 创建测试 topic
kafka-topics.sh --bootstrap-server localhost:9092 --create --topic test-topic --partitions 1 --replication-factor 1

# 列出 topic
kafka-topics.sh --bootstrap-server localhost:9092 --list

# 发送测试消息
echo "hello kafka" | kafka-console-producer.sh --bootstrap-server localhost:9092 --topic test-topic

# 消费测试消息
kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test-topic --from-beginning
```

### 4. 从另一容器验证 (跨容器网络)

```bash
# 使用临时容器运行 kafka 客户端工具验证连通性
docker run --rm --network kyb-net \
  apache/kafka:latest \
  kafka-topics.sh --bootstrap-server kyb-infra-kafka:9092 --list
```

或者使用通用网络工具验证:

```bash
# 从 kyb-infra-boss 测试
docker exec kyb-infra-boss bash -c 'echo | nc -w 3 kyb-infra-kafka 9092 && echo "Port 9092 open" || echo "Connection refused"'
```

### 5. 从宿主机验证

```bash
# 安装 kcat (以前叫 kafkacat) 或用任何 Kafka 客户端
# kcat -b localhost:9092 -L
# 或用 Python:
python3 -c "
from kafka import KafkaAdminClient
admin = KafkaAdminClient(bootstrap_servers='localhost:9092')
print('Connected! Topics:', admin.list_topics())
"
```

## 资源与调优

### 内存

| 配置 | 值 | 说明 |
|------|-----|------|
| `KAFKA_HEAP_OPTS` | `-Xmx512m -Xms512m` | JVM 堆 512MB |
| 总内存占用 | ~600-800MB | 含 JVM 堆外 + OS 页缓存 |

对于开发/测试环境 512MB 堆足够。生产环境建议 2-4GB。

### 磁盘

| 挂载点 | 存储 | 说明 |
|--------|------|------|
| `/var/lib/kafka/data` | `kafka-data` volume | 日志数据 |

默认日志保留 7 天。开发环境可调低:

```bash
# 附加环境变量缩短保留期
-e KAFKA_LOG_RETENTION_HOURS=24
-e KAFKA_LOG_RETENTION_BYTES=1073741824   # 1GB
```

### OS 页缓存

Kafka 严重依赖 OS 页缓存。macOS 上的 Orbstack Docker VM 自动管理内存，但需要注意:
- 如果 kyb-infra 容器组整体内存不足，考虑增加 Orbstack 内存配额
- 当前 kyb-infra-boss + kyb-infra-sing-box 占用约 ~200MB，Kafka 增加 ~600-800MB
- Orbstack 默认通常有 4-8GB 可用，足够

## 网络架构

```
┌──────────────────────────────────────────────┐
│  kyb-net (192.168.97.0/24)                   │
│                                              │
│  ┌──────────────────┐  ┌──────────────────┐  │
│  │ kyb-infra-kafka  │  │ 其他容器          │  │
│  │ 192.168.97.x     │  │ (boss, sing-box) │  │
│  │ :9092 (PLAINTEXT) │  │                  │  │
│  │ :9093 (CONTROLLER)│  │                  │  │
│  └────────┬─────────┘  └──────────────────┘  │
│           │                                   │
└───────────┼───────────────────────────────────┘
            │
            │ port 9092 (宿主机映射)
            ▼
     macOS 应用 / 其他客户端
```

- 容器间: `kyb-infra-kafka:9092`
- 宿主机: `localhost:9092`
- 代理: 不需要 (Kafka 不依赖外网访问)

## 常见问题和处理

### Q: 容器启动后立即退出

**原因**: KRaft 模式需要初始化日志目录。第一次启动时可能因为 `/var/lib/kafka/data` 为空而失败。

**解决**: 先创建好目录结构:

```bash
docker run --rm --entrypoint sh apache/kafka:latest -c "
  mkdir -p /var/lib/kafka/data
  # 初始化 KRaft 集群 ID
  export CLUSTER_ID=\$(/opt/kafka/bin/kafka-storage.sh random-uuid)
  /opt/kafka/bin/kafka-storage.sh format -t \$CLUSTER_ID -c /opt/kafka/config/kraft/server.properties
"
```

或者检查日志:

```bash
docker logs kyb-infra-kafka 2>&1 | tail -30
```

如果是因为未格式化，手动格式化:

```bash
docker exec kyb-infra-kafka bash -c "
  CLUSTER_ID=\$(kafka-storage.sh random-uuid) && \
  kafka-storage.sh format -t \$CLUSTER_ID -c /opt/kafka/config/kraft/server.properties
"
```

### Q: 宿主机无法连接

**原因**: `ADVERTISED_LISTENERS` 设置为容器 DNS 名，宿主机无法解析。

**解决**: 两种方案:

1. (推荐) 宿主机通过 `localhost:9092` 连接 — 端口映射到宿主机 9092
2. 如果要设置双 advertised listener (容器间用 DNS，宿主机用 localhost):

```bash
-e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kyb-infra-kafka:9092,PLAINTEXT_HOST://localhost:9092"
-e KAFKA_LISTENERS="PLAINTEXT://0.0.0.0:9092,PLAINTEXT_HOST://0.0.0.0:9094"
# 添加 LISTENER_SECURITY_PROTOCOL_MAP 中加上 PLAINTEXT_HOST:PLAINTEXT
```

但单节点开发用最简单方案即可 — 容器间用 `kyb-infra-kafka:9092`，宿主机用 `localhost:9092`。

### Q: 端口 9092 已被占用

```bash
lsof -i :9092
# 或
docker run --rm --network host alpine sh -c "nc -zv localhost 9092"
```

如果宿主机有其他进程占用，映射到不同端口，如 `9095:9092`:

```bash
-p 9095:9092 \
```

更新客户端连接地址为 `localhost:9095`。

### Q: 镜像 pull 失败 (rate limit / 网络)

使用的 registry mirror: `docker.xuanyuan.me`。如果该 mirror 限流:

- 添加 GitHub Container Registry 为备选: `ghcr.io/apache/kafka`
- 或通过代理 pull: `ALL_PROXY=socks5://kyb-infra-sing-box:2080 docker pull apache/kafka:latest`

### Q: KRaft 模式兼容性

项目中使用 Kafka 客户端需要确保 broker 版本兼容:

- `apache/kafka:latest` 通常对应 Kafka 4.x，客户端建议用 3.5+
- 如需特定版本: `apache/kafka:3.7.0`、`apache/kafka:3.8.0` 等

## 备用方案: 传统 Zookeeper 模式

如果 KRaft 模式遇到无法解决的问题，回退到 Zookeeper 模式。

### Zookeeper 容器

```bash
docker volume create zookeeper-data

docker run -d \
  --name kyb-infra-zookeeper \
  --network kyb-net \
  --restart unless-stopped \
  -v zookeeper-data:/data \
  -e ZOOKEEPER_CLIENT_PORT=2181 \
  -e ZOOKEEPER_TICK_TIME=2000 \
  -e ALLOW_ANONYMOUS_LOGIN=yes \
  bitnami/zookeeper:latest
```

### Kafka 容器 (Zookeeper 模式)

```bash
docker volume create kafka-data

docker run -d \
  --name kyb-infra-kafka \
  --network kyb-net \
  --restart unless-stopped \
  -p 9092:9092 \
  -v kafka-data:/var/lib/kafka/data \
  -e KAFKA_ZOOKEEPER_CONNECT=kyb-infra-zookeeper:2181 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kyb-infra-kafka:9092 \
  -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
  -e KAFKA_HEAP_OPTS="-Xmx512m -Xms512m" \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  bitnami/kafka:latest
```

## 清理和卸载

```bash
# 停容器
docker stop kyb-infra-kafka
# 删容器
docker rm kyb-infra-kafka
# 删数据卷
docker volume rm kafka-data
# 如果用了 ZK:
docker stop kyb-infra-zookeeper
docker rm kyb-infra-zookeeper
docker volume rm zookeeper-data
```

## 总结

单容器 KRaft 模式是 kyb-infra 部署 Kafka 的最优方案:

- **简单**: 一个容器，无 ZK 依赖
- **兼容**: ARM64/macOS 原生支持
- **低成本**: 512MB 堆足够开发测试
- **标准**: 容器名 `kyb-infra-kafka` 符合 kyb-infra 命名约定
- **网络**: 接入 `kyb-net`，容器间通过 DNS 通信，宿主机通过 `localhost:9092` 连接

启动命令汇总:

```bash
# 0. 拉镜像 (如果还未拉取)
docker pull apache/kafka:latest

# 1. 创建数据卷
docker volume create kafka-data

# 2. 启动 Kafka (KRaft 模式)
docker run -d \
  --name kyb-infra-kafka \
  --network kyb-net \
  --restart unless-stopped \
  -p 9092:9092 \
  -v kafka-data:/var/lib/kafka/data \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS="1@kyb-infra-kafka:9093" \
  -e KAFKA_LISTENERS="PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093" \
  -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kyb-infra-kafka:9092" \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_HEAP_OPTS="-Xmx512m -Xms512m" \
  apache/kafka:latest

# 3. 确认启动
docker ps --filter name=kyb-infra-kafka

# 4. 测试
docker exec kyb-infra-kafka \
  kafka-topics.sh --bootstrap-server localhost:9092 --list

# 5. 监测日志
docker logs -f kyb-infra-kafka 2>&1 | tail -50
```
