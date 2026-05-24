# 代码架构

kyb 的 Ruby 代码怎么组织的。我写的，我清楚哪里好哪里烂。

---

## 模块结构

```
bin/kyb              ← 入口
lib/kyb/
  ├── kyb.rb         ← 核心 + 工具方法
  ├── config.rb      ← YAML 配置
  ├── parser.rb      ← 参数解析 + 校验
  ├── docker.rb      ← Docker API (这里最烂)
  ├── container.rb   ← 容器模型
  ├── proxy.rb       ← 代理设置
  ├── reporter.rb    ← CK 上报
  ├── exit_flow.rb   ← 退出清理
  ├── check.rb       ← 预检
  ├── tts_server.rb  ← 语音通知
  └── cli/           ← 每个命令一个文件
```

## 几个设计选择

**零依赖。** kyb 只用了 Ruby stdlib。不是因为我多喜欢 Ruby，是因为少一个依赖少一个坑。Tebako 可以把 stdlib 编译成单文件二进制，部署就一个文件。

**每个 CLI 命令一个文件。** `cli/create.rb`、`cli/enter.rb`... 这样加新命令不用改已有代码，删命令也简单。代价是有一些重复（project-branch 解析在好几个文件里重复了），但我宁可再生抽取也不过早抽象。

**Docker 操作全在 docker.rb。** 其他地方不直接调 docker CLI。这个决定是对的——当我要加 Shellwords.escape 的时候只需要改一个文件。

**Config 延迟加载。** 不启动就读全部配置，用到哪个 project 读哪个。没什么特别的理由，只是觉得启动快一点舒服。

## 我知道烂的地方

### Docker.run 一坨（115 行）

什么都在里面：DinD 逻辑、非 DinD 逻辑、mount、volume、port、proxy。拆是肯定要拆的，但每次打开它我都觉得"下次再说"。

### 测试污染（修了一半）

有人用了 `define_singleton_method` 来 mock，这个会永久替换 module_function，跨测试文件污染。我已经修了 3 个文件，还剩下 `test_reporter.rb` 和 `test_metrics.rb`。CI 有时候红就是因为这个。

### CI 里 30% 的测试被跳过

Docker/container 相关的测试在 CI 环境跑不了。这意味着每次改 docker.rb 我都不确定 CI 能不能测到。应该在本地跑一遍再推。

## 关于 Go 重写

我认真想过要不要用 Go 重写。评估结果是：13-16 天，功能零增长，双代码库维护。不划算。
