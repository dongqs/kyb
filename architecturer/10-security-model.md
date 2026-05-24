# Security Model

我的安全边界。信任模型、已知攻击面、防御措施。

---

## 信任模型

```
宿主机 (macOS)        信任边界 1
    │
    ▼
kyb-infra-boss       信任边界 2 (Docker socket 直通)
    │
    ├── 容器管理 → Docker socket ← 容器逃逸风险
    │
    ├── nuc8 隧道 → SSH key → GitLab
    │
    └── 飞书桥 → 认证 token → Feishu API

Sandbox 容器          信任边界 3 (用户项目代码)
    │
    ├── repo mount (rw) → 宿主目录可写
    ├── PG 直连 → 无密码
    └── 代理出口 → 外网可达
```

**威胁模型：** trusted workload。容器逃逸可导致宿主机沦陷。

## 已修复的注入面

| # | 位置 | 漏洞 | 修复 |
|---|------|------|------|
| 1 | `check.rb` | `` `#{cmd}` `` 反引号注入 | `Open3.capture3('sh', '-c', cmd)` |
| 2 | `docker.rb` | `` `docker ps -a --filter name=kyb-#{name}` `` | Shellwords.escape |
| 3 | `exit_flow.rb` | `` `docker exec #{cname} ps` `` | 参数化调用 |
| 4 | `entrypoint.sh` | Heredoc `<< YAML` 未引用 | `<< 'YAML'` |
| 5 | `entrypoint.sh` | `sed -i s|TOKEN|${GITLAB_TOKEN}|g` 分隔符冲突 | `sed -i s|TOKEN_PLACEHOLDER|...|g` |

全局修复：`Shellwords.escape` 已覆盖所有命令拼接点。

## 防御措施

| 措施 | 状态 |
|------|------|
| 无 `--privileged` 容器 | ✅ |
| 无 `--cap-add` 额外权限 | ✅ |
| SSH key `chmod 600` | ✅ |
| glab config `chmod 600` | ✅ |
| 敏感路径 `:ro` 挂载 | ✅ |
| YAML.safe_load_file | ✅ (无 Psych RCE) |
| 参数白名单校验 (`--model`, `--cli`) | ✅ |
| Branch 名正则校验 | ✅ (MR !123) |
| Docker secrets (替代 -e 传 key) | ❌ 待做 |
| 容器创建限流 | ❌ 待做 |

## 未修复的高风险项

| 风险 | 原因 | 优先级 |
|------|------|--------|
| API Key 通过 `-e` 传环境变量 (`ps aux` 可见) | 需改 Docker secrets | P2 |
| `rescue Exception` 吞 SignalException | `exit_flow.rb` | P2 |
| 无容器创建限流 | 可能被滥用 | P3 |
