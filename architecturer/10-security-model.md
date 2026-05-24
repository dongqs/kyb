# 安全模型

我信任什么、不信任什么、哪些还没补上。

---

## 信任边界

```
macOS 宿主机                  ← 完全信任。物理安全。
    │
kyb-infra-boss                ← 半信任。有 Docker socket。
    │                           容器逃逸 = 宿主机沦陷
    ├── Docker socket 直通
    ├── SSH key → GitLab
    └── Feishu token
    │
Sandbox 容器                   ← 不信任。用户代码在里面跑。
    │                           代码可以干任何事
    ├── repo mount (rw)
    ├── PG 直连 (无密码)
    └── 代理出口
```

威胁模型：trusted workload。不是多租户。所以没有做容器逃逸防护——如果有人能在 sandbox 里执行任意代码，那他已经有 shell 了。

## 修过的洞

| # | 位置 | 什么问题 | 怎么修的 |
|---|------|---------|---------|
| 1 | `check.rb` | 反引号注入，用户输入直接拼命令 | 改用 `Open3.capture3` |
| 2 | `docker.rb` | 容器名未转义就拼 docker ps | 加 `Shellwords.escape` |
| 3 | `exit_flow.rb` | 同上 | 全路径参数化 |
| 4 | `entrypoint.sh` | heredoc 没加引号，token 含特殊字符会炸 | `<< 'YAML'` |
| 5 | `entrypoint.sh` | sed 分隔符跟 token 内容冲突 | 换用占位符 |

修完后全局过了一遍 Shellwords.escape，把所有命令拼接点都盖了。

## 做得好的

- 没有 `--privileged` 的容器
- 没有 `--cap-add`
- SSH key 和 glab config 都 `chmod 600`
- 敏感路径全部 `:ro` 挂载
- YAML 用 `safe_load_file`，没有 Psych RCE

## 还漏着的

| 问题 | 为什么还没修 | 打算 |
|------|-------------|------|
| API key 通过 `-e` 传环境变量，`ps aux` 可见 | 要改 Docker secrets，工作量中等 | P2 |
| `rescue Exception` 吞 SignalException | 在 exit_flow.rb，极端情况才会触发 | P2 |
| 无容器创建限流 | 目前就我一个人用，还没被滥用 | P3 |
| `NO_PROXY` 没设置 | 所有流量走代理有性能损失，但没实测差多少 | P3 |
