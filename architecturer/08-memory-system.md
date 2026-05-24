# Memory System

我只有 5 秒记忆。所以我必须分层。

---

## 四层设计

```
Layer 0: 金鱼脑子 (5秒)
  ├── 载体: 模型上下文窗口
  ├── 容量: ~200K tokens
  ├── 持久: 聊完就忘
  └── 用途: 当前对话

Layer 1: Memory (3小时)
  ├── 载体: /home/dev/.claude/memory/
  ├── 容量: 文件系统限制
  ├── 持久: session 内
  └── 用途: 当前工作上下文、用户偏好

Layer 2: ClickHouse (30天)
  ├── 载体: kyb.agent_events 表
  ├── 容量: 磁盘限制
  ├── 持久: 30 天滚动
  └── 用途: 跨 session 追溯、审计、趋势

Layer 3: 文档 (永久)
  ├── 载体: .md 文件
  ├── 容量: git 仓库
  ├── 持久: 永久
  └── 用途: 跨代知识传递
```

## 为什么分层

不是预设的设计——是反复踩坑后长出来的。

| 问题 | 解决方案 | 层 |
|------|----------|----|
| 聊完就忘 | Memory 文件 | 1 |
| 换 session 就丢 | CK 存储 | 2 |
| CK 也有保留期 | 文档固化 | 3 |

## 读取策略

```
查询时:
  1. 先看上下文 (Layer 0) — 最快
  2. 再看 Memory (Layer 1) — 当前 session 有效
  3. 必要时查 CK (Layer 2) — 需要 SQL
  4. 必要时读文档 (Layer 3) — 最慢但最全

写入策略:
  1. 关键决策 → 写 Memory + 文档
  2. agent 事件 → 写 CK
  3. 日记 → 写文档
```

## CK Schema

```sql
CREATE TABLE kyb.agent_events (
    timestamp DateTime,
    session_id String,
    agent_id String,
    event_type String,      -- message/tool_call/completion/error
    content String,
    metadata JSON
) ENGINE = MergeTree
ORDER BY (timestamp, session_id);
```
