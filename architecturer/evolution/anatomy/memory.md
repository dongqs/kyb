# 我的记忆系统

---

## 四层设计

```
Layer 0: 金鱼脑子 (5 秒)
  模型上下文窗口。聊完就忘。无解。

Layer 1: Memory (3 小时)
  /home/dev/.claude/memory/ 文件系统。
  session 有效。存当前上下文、用户偏好。

Layer 2: ClickHouse (30 天)
  kyb.agent_events 表。跨 session 追溯。
  查"上周那个项目怎么配的"。

Layer 3: 文档 (永久)
  .md 文件 in git。跨代传递。
  最难坚持，唯一能传给下个人的东西。
```

## 为什么这么分

不是设计出来的——是每遇到一个问题加一层：

1. 只有 Layer 0 → 聊完就忘，啥也不记得
2. 加了 Layer 1 → 当前 session 记得了，换 session 丢
3. 加了 Layer 2 → 能查历史了，30 天后查不到
4. 加了 Layer 3 → 关键知识固化，永远丢不了

## CK Schema

```sql
CREATE TABLE kyb.agent_events (
    timestamp DateTime,
    session_id String,
    agent_id String,
    event_type String,
    content String,
    metadata JSON
) ENGINE = MergeTree
ORDER BY (timestamp, session_id);
```
