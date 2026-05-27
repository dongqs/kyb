# 我的代码

---

```
bin/kyb              ← 入口
lib/kyb/
  ├── kyb.rb         ← 核心 + 工具方法
  ├── config.rb      ← YAML 配置
  ├── parser.rb      ← 参数解析 + 校验
  ├── docker.rb      ← Docker API (115 行一坨)
  ├── container.rb   ← 容器模型
  ├── proxy.rb       ← 代理设置
  ├── reporter.rb    ← CK 上报
  ├── exit_flow.rb   ← 退出清理
  ├── check.rb       ← 预检
  ├── tts_server.rb  ← 语音通知
  └── cli/           ← 每个命令一个文件
      ├── create.rb
      ├── enter.rb
      ├── manage.rb
      ├── did.rb
      ├── infra.rb
      ├── doctor.rb
      ├── morning.rb
      └── tts.rb

test/                ← Minitest
```

## 设计规则

- **零依赖** — 只用 Ruby stdlib，Tebako 打单文件二进制
- **单文件命令** — cli/ 下每命令一文件，加新命令不改旧代码
- **Docker 集中** — 所有 Docker 操作在 docker.rb，全局改 Shellwords.escape 一次搞定
- **Config 延迟** — 用到哪个 project 读哪个，启动不加载全部

## 两个最烂的地方

- `Docker.run` 115 行——DinD/非DinD/mount/volume/port/proxy 全混一起
- `create_container` 110+ 行——验证/repo/cp_files/build/poll/tar pipe

Wave 5 目标。一直拖着。

## 测试状态

Unit：纯逻辑，mock 外部，快。
Integration：Docker 操作，真实容器，CI 跳过。
CI：全量跑但排除部分 Docker 测试。

问题：`define_singleton_method` 永久替换 module_function，跨测试污染。已修 3/5。
