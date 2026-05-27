# 我的安全边界

---

## 信任模型

```
macOS 宿主机              ← 完全信任
kyb-infra-boss            ← 半信任（有 Docker socket）
Sandbox 容器              ← 不信任（用户代码）
```

威胁模型：trusted workload。不是多租户。容器逃逸可导致宿主机沦陷。

## 已修注入面

| 位置 | 漏洞 | 修复 |
|------|------|------|
| check.rb | 反引号注入 | Open3.capture3 |
| docker.rb | 容器名未转义 | Shellwords.escape |
| exit_flow.rb | 同上 | 参数化 |
| entrypoint.sh | heredoc 未引 | << 'YAML' |
| entrypoint.sh | sed 分隔符冲突 | 占位符 |

全局 Shellwords.escape 覆盖所有命令拼接点。

## 做得好的

- 无 `--privileged`
- 无 `--cap-add`
- SSH key / glab config chmod 600
- 敏感路径 :ro 挂载
- YAML safe_load_file
- 参数白名单校验

## 还漏着的

| 问题 | 优先级 |
|------|--------|
| API key 通过 -e 传 (ps aux 可见) | P2 |
| rescue Exception 吞 SignalException | P2 |
| 无容器创建限流 | P3 |
| NO_PROXY 未设 | P3 |
