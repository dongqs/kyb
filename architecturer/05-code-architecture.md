# Code Architecture

我由 Ruby 写成，依赖只有 stdlib。这是我的代码结构。

---

## 模块图

```
bin/kyb                 ← CLI 入口 (可执行)
    │
lib/kyb/
    ├── kyb.rb          ← 核心 module: Kyb.die, Kyb.in_container?
    ├── config.rb       ← YAML 配置加载 + project 解析
    ├── parser.rb       ← branch/container 名解析 + 校验
    ├── docker.rb       ← Docker API 封装 (run/create/exec)
    ├── container.rb    ← Container 模型
    ├── proxy.rb        ← 代理设置
    ├── reporter.rb     ← CK 事件上报
    ├── exit_flow.rb    ← 退出清理 (容器/volume/进程)
    ├── check.rb        ← 预检 (disk/network/docker)
    ├── tts_server.rb   ← TTS 语音通知 HTTP 服务
    │
    └── cli/
        ├── create.rb   ← kyb create
        ├── enter.rb    ← kyb enter/exec
        ├── manage.rb   ← kyb ps/start/stop/rm/prune
        ├── did.rb      ← kyb did (Docker-in-Docker)
        ├── infra.rb    ← kyb infra create/enter
        ├── doctor.rb   ← kyb doctor (诊断)
        ├── morning.rb  ← kyb morning (晨检)
        └── tts.rb      ← kyb tts/notify

test/
    ├── test_config.rb
    ├── test_docker.rb
    ├── test_parser.rb
    ├── test_entrypoint.rb
    ├── test_reporter.rb
    ├── test_metrics.rb
    └── ...
```

## 设计规则

| 规则 | 原因 |
|------|------|
| 零运行时依赖 | stdlib only。Tebako 打单文件二进制 |
| CLI 命令=独立文件 | 每个命令一个文件，避免 kitchen sink |
| Docker 操作集中 | `docker.rb` 封装所有 API 调用，其他地方不直接调 docker |
| 配置延迟加载 | `Config.project` 按需加载，避免启动时全量解析 |
| 退出流程兜底 | `exit_flow.rb` 确保容器/volume 清理，不泄漏 |

## 两个肥大方法（待拆分）

| 方法 | 行数 | 混了什么 |
|------|------|----------|
| `Docker.run` | 115+ | DinD/non-DinD/mount/volume/port/proxy 全混在一起 |
| `Docker.create_container` | 110+ | 验证/repo/cp_files/image build/ready poll/tar pipe |

Wave 5 目标，还没做。

## 测试架构

| 层级 | 覆盖 | 策略 |
|------|------|------|
| Unit | 纯逻辑 (parser/config) | mock 外部，快速 |
| Integration | Docker 操作 | 真实容器，标记跳过 |
| CI | 全量 | 排除部分 Docker 测试（环境限制）|

问题：`define_singleton_method` 永久替换 module_function，跨文件污染。已修 3 个文件，还剩 `test_reporter.rb` 和 `test_metrics.rb`。
