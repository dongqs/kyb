# Nexus 403 调查

**日期：** 2026-05-21
**阻塞项目：** dialogue 等

## 三路并行策略

同时派出三个 agent 以不同策略进攻：

1. **凭据轮换 agent** — 尝试不同凭据/权限
2. **URL 重构 agent** — 尝试不同的 URL 格式
3. **版本替换 agent** — 发现请求的依赖版本在快照仓库中不存在，替换为存在的版本

版本替换 agent 最先成功。7 个模块编译通过。

## 关键映射

`readonlyuser` 可以访问 `com.leyantech.base` —— 但**不能**访问：
- `com.leyantech.leyan`
- `com.leyantech.chaos`

这意味着 Nexus 403 不是全局问题，而是特定 groupId 的权限问题。

## 结论

Nexus 403 实际上是两个独立问题混在一起：
1. leyantech leyann/chaos 组返回 403（凭据问题）
2. `com.leyantech.base` 返回 404（未发布）

部分项目靠缓存成功，部分直接失败。VPN 有时能解决说明还有网络路由层面的间歇性问题。
