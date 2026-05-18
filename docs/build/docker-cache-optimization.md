# Dockerfile 构建缓存优化

## 问题

`mise.config.toml` 在 Dockerfile 第 63 行（COPY），在其之后有 10+ 个 RUN 层。
每次修改 `mise.config.toml`（加/删工具、改版本）会断掉后续所有缓存层：

```
COPY mise.config.toml    → cache MISS（配置改动）
mise install             → 全部工具重装（即使 cache mount 命中下载）
mirror configs           → 重建（快）
mig25 pip install        → 重建（pip cache 命中则快）
kimi-cli                 → 重建（脚本执行，~30s）
playwright chromium      → 重建（ms-playwright cache 命中则快）
kyb CLI                  → 重建（快）
```

## 根因

- Mise config 位于 Dockerfile 中段，其后的 100+ 行都依赖它
- `mise install` 一次装所有工具，任何一个工具的版本变化都导致全部重装
- `--mount=type=cache` 的 cache mount 在新 layer 执行时可能重新分配 cache key

## 优化方案（待实现）

### 方案 A：分层 mise install

将 tools 拆分到不同的 COPY + RUN 对中，稳定工具（node/python/ruby）放前面，
实验性/易变工具（maven/glab）放后面：

```dockerfile
# 稳定层 — 几乎不变
COPY mise-stable.toml /home/dev/.config/mise/stable.toml
RUN mise install node python ruby

# 中等层 — 偶尔变
COPY mise-medium.toml /home/dev/.config/mise/medium.toml
RUN mise install maven glab clickhouse

# 变动层 — 频繁变
COPY mise-unstable.toml /home/dev/.config/mise/unstable.toml
RUN mise install claude-code
```

### 方案 B：mise config 后移

把 `COPY mise.config.toml` 移到 Dockerfile 末尾，只影响 archive 层。
代价：mise install 发生的晚，前面的 Dockerfile 层不能利用 mise 工具。

### 方案 C：cache mount key 固定

显式指定 `--mount=type=cache,id=mise-downloads` 固定 cache identity，
避免 layer 重构时 cache 分配新 key。
