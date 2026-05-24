# kyb 启动锁设计方案

> Issue: https://git.leyantech.com/quick-n-dirty/kyb/-/issues/170
> Status: Round 2 — 从方案 C 切换至方案 A'（交互式同意 + env bypass）
> 等级: **L1**（单一开发者体验，出问题不影响生产环境）
>
> **铁律：本设计方案在 10 人审查通过前，任何人不得写任何代码。**

---

## 1. 问题定义

### 1.1 背景

kyb 项目目前的状态：clone 下来后直接运行 `kyb` 即可使用所有功能。对于一个管理 Docker 容器的 CLI 工具，这存在两个风险：

1. **意外执行** — 新环境 clone 后，在不了解项目功能的情况下误触 `kyb` 命令，可能导致意外创建/删除容器
2. **责任归属缺失** — 没有明确的"授权步骤"，操作记录中无法区分"用户知情执行"和"误触/脚本恶意执行"

### 1.2 目标

- 首次运行 `kyb` 时必须经过显式授权
- 授权后不再重复提示（合理时间段内）
- 团队/CI 环境可通过配置跳过授权
- 最小侵入性：改动不超过 50 行 Ruby
- 不自毁：启动锁自身逻辑不能破坏 kyb 原有功能（参考 P0 infra-boss 自保原则）

### 1.3 非目标

- 不实现加密/签名级别的安全校验
- 不做网络层面的访问控制
- 不涉及用户身份认证

---

## 2. 方案对比

### 方案 A：纯交互式同意（基线方案）

**原理**：首次运行时打印授权协议文本，要求用户输入 `yes` 确认。确认后在 `~/.config/kyb/.consent` 写入标记文件。后续运行检查该文件存在则跳过。

**流程**：

```
$ kyb
==> kyb 首次启动需要您的同意
==> kyb 是一个 Docker 沙箱管理工具，可以创建/删除容器。
==> 继续使用即表示您了解以上行为。
==> 请输入 yes 确认：yes
==> 感谢！继续执行...
```

**代码量**：约 10 行 Ruby

```ruby
# 伪代码示意
def startup_lock
  consent_file = File.expand_path('~/.config/kyb/.consent')
  return if File.exist?(consent_file)

  puts "==> kyb 首次启动需要您的同意..."
  input = $stdin.gets.strip
  if input == 'yes'
    File.write(consent_file, Time.now.to_s)
  else
    exit 1
  end
end
```

**优点**：
- 实现简单，改动极小
- 用户可见，无隐藏行为
- 无外部依赖

**缺点**：
- **易被绕过** — 空文件（`touch .consent`）即可跳过
- **非交互环境无法使用** — CI、管道、`kyb exec` 等场景无法输入 `yes`
- **无团队管控能力** — 无法为团队统一配置跳过
- **标记文件可被意外删除** — `kyb prune` 或其他清理操作可能误删

**适用场景**：个人开发环境，低风险。

---

### 方案 B：解锁码

**原理**：首次运行时要求输入解锁码。解锁码通过环境变量或在 `~/.config/kyb/config.yml` 中配置。匹配后生成 `.consent` 标记文件。

**流程**：

```
# 首次运行（无解锁码）
$ kyb
==> kyb 需要解锁码才能使用。
==> 请输入解锁码：

# 首次运行（有环境变量）
$ KYB_UNLOCK_KEY=mykey kyb
==> 解锁码验证通过。继续执行...
```

**代码量**：约 30 行 Ruby

```ruby
# 伪代码示意
def startup_lock
  consent_file = File.expand_path('~/.config/kyb/.consent')
  return if File.exist?(consent_file)

  expected = ENV['KYB_UNLOCK_KEY'] || config.dig('startup_lock', 'unlock_key')
  return unless expected

  print "==> 请输入解锁码："
  input = $stdin.gets&.strip
  if input == expected
    File.write(consent_file, Time.now.to_s)
  else
    die "解锁码错误"
  end
end
```

**优点**：
- 安全性最高
- 可控性强 — 可随时更换解锁码
- 支持 CI/团队场景（环境变量传入）

**缺点**：
- **密钥管理负担** — 解锁码需要安全分发，丢失后无法使用 kyb
- **UX 差** — 每次新环境都需要找解锁码，增加摩擦
- **解锁码泄露** — 环境变量可能被进程列表、日志等泄露
- **复杂度提升** — 需要处理解锁码的配置、校验、错误提示

**适用场景**：需要管控谁可以使用 kyb 的团队环境。

---

### 方案 A'：交互式同意 + 环境变量跳过（推荐）

**原理**：基于方案 A 的交互式同意，增加环境变量和配置跳过选项。不引入"解锁码"，用 `KYB_STARTUP_BYPASS=true` 布尔开关替代。与方案 C（Round 1 推荐）的关键区别：

- **`KYB_STARTUP_BYPASS` 替代 `KYB_UNLOCK_KEY`** — 布尔语义，任意非空值不保证放行（只认 `true`）
- **`.consent` 内容校验** — 写入 `kyb-consent:v1` + 时间戳，空文件不可绕过
- **非 TTY 自动跳过** — 不阻塞 cron/SSH exec/管道
- **`--help`/`--version` 不触发的** — 新用户查看帮助不受阻碍
- **版本锚定** — `.consent` 带版本号，支持未来升级时重新同意
- **重试机制** — 输错不 exit，可重试

**检查优先级**：

```
startup_lock()
  │
  ├─ [1] ~/.config/kyb/.consent 存在且内容合法?
  │      ├─ yes → 静默通过
  │      └─ no  → 继续
  │
  ├─ [2] ENV['KYB_STARTUP_BYPASS'] == 'true'?
  │      ├─ yes → 写入 .consent → 静默通过
  │      └─ no  → 继续
  │
  ├─ [3] config.yml startup_lock.enabled == false?
  │      ├─ yes → 静默通过
  │      └─ no  → 继续
  │
  ├─ [4] $stdin.tty? == false?
  │      ├─ yes → 静默跳过（非交互式不阻塞）
  │      └─ no  → 继续
  │
  └─ [5] 交互式提示
         ├─ yes → 写入 .consent → 继续执行
         ├─ 其他输入 → 重试提示（不 exit）
         └─ EOF (Ctrl+D) → exit 1
```

**流程**：

```
# 场景 1：用户同意过
$ kyb
（静默通过，无输出）

# 场景 2：首次运行
$ kyb
╔══════════════════════════════════════════════════════════╗
║                    kyb 启动确认                          ║
╠══════════════════════════════════════════════════════════╣
║ kyb 是一个 Docker 沙箱管理工具，可以：                    ║
║  • 创建/删除 Docker 容器                                 ║
║  • 在容器中执行命令                                      ║
║  • 管理容器生命周期（启动/停止/删除）                     ║
║                                                          ║
║ 继续使用即表示您了解以上行为。                            ║
║                                                          ║
║ 输入 yes 确认，或输入任意内容取消。                      ║
║ 如需在 CI/非交互环境中跳过，设置环境变量：                ║
║   export KYB_STARTUP_BYPASS=true                          ║
║ 或通过配置文件永久禁用：                                  ║
║   # ~/.config/kyb/config.yml                              ║
║   startup_lock:                                           ║
║     enabled: false                                        ║
╚══════════════════════════════════════════════════════════╝
> yes
==> 感谢确认。继续执行...

# 场景 3：CI 环境
$ KYB_STARTUP_BYPASS=true kyb build
（静默通过，并写入 .consent 供后续使用）

# 场景 4：显式禁用
$ cat ~/.config/kyb/config.yml
startup_lock:
  enabled: false
$ kyb
（静默通过）

# 场景 5：非 TTY（SSH exec/管道/cron）
$ echo kyb ps | ssh server
（自动跳过，不阻塞）
```

**代码量**：约 50 行 Ruby

```ruby
# 伪代码示意
def self.check(consent_path:, input_io:, env:)
  # [1] 已同意过（带内容校验）
  return if valid_consent?(consent_path)

  # [2] 环境变量跳过（布尔开关）
  if env['KYB_STARTUP_BYPASS'] == 'true'
    write_consent(consent_path, 'bypass:env')
    return
  end

  # [3] 配置中显式禁用
  config = Kyb::Config.load rescue {}
  return unless config.dig('startup_lock', 'enabled') != false

  # [4] 非 TTY 自动跳过（不阻塞 cron/SSH exec）
  return unless input_io.tty?

  # [5] 交互式同意（带重试）
  print_consent_notice
  loop do
    print '> '
    input = input_io.gets&.strip
    if input == 'yes'
      write_consent(consent_path, 'consented')
      puts '==> 感谢确认。继续执行...'
      return
    elsif input.nil?
      exit 1
    else
      puts '输入 yes 确认，或设置 KYB_STARTUP_BYPASS=true 跳过。'
    end
  end
end
```

**优点**：
- **覆盖所有场景** — 交互式 + CI + 非 TTY + 团队，不留死角
- **不引入密钥管理** — 无解锁码，无分发/泄露风险
- **`.consent` 防绕过** — 内容格式校验，空文件无效
- **非 TTY 不阻塞** — 不影响管道/SSH exec/cron 工作流
- **渐进式** — 个人用同意，CI 用环境变量，不需要则禁用
- **向后兼容** — 不配置任何东西的老用户不受影响

**缺点**：
- 比方案 A 多 ~40 行代码
- 环境变量跳过无认证（团队场景需配合其他管控）

---

### 2.1 方案综合对比

| 维度 | 方案 A（纯交互式） | 方案 B（解锁码） | 方案 A'（推荐） |
|------|:---:|:---:|:---:|
| 代码量 | ~10 行 | ~30 行 | ~50 行 |
| 实现难度 | ★☆☆ | ★★☆ | ★★☆ |
| 安全性 | ★☆☆（空文件绕过） | ★★★（需知码） | ★★☆（内容校验） |
| 用户体验 | ★★☆ | ★☆☆ | ★★★ |
| CI 兼容性 | ★☆☆ | ★★★ | ★★★ |
| 非 TTY 兼容 | ★☆☆ | ★★★ | ★★★ |
| 团队管控 | ★☆☆ | ★★★ | ★☆☆（无认证） |
| 维护成本 | ★☆☆ | ★★★ | ★★☆ |

---

## 3. 推荐方案：方案 A' 详细设计

### 3.1 `.consent` 文件格式与校验

**写入格式**（两行）：

```
kyb-consent:v1
consented:2026-05-25T10:30:00+08:00
```

第一行是版本标识，固定为 `kyb-consent:v1`。
第二行是同意类型和时间戳：
- `consented:2026-05-25T10:30:00+08:00` — 交互式同意
- `bypass:env` — 通过环境变量 `KYB_STARTUP_BYPASS` 跳过
- `bypass:config` — 通过配置 `startup_lock.enabled: false` 跳过

**读取校验**：

```ruby
CONSENT_VERSION = 'v1'

def self.valid_consent?(path)
  return false unless File.exist?(path)
  content = File.read(path)
  first_line = content.lines.first&.strip
  first_line == "kyb-consent:#{CONSENT_VERSION}"
rescue StandardError
  false  # 文件损坏/不可读 → 视为未同意
end
```

**设计理由**：
- 防止空文件绕过（`touch ~/.config/kyb/.consent` 无效）
- 版本锚定（`v1`）：未来 kyb 增加危险能力时，切换到 `v2` 要求用户重新同意
- 两行格式简洁，兼容性好
- 文件损坏时 fail-open（视为未同意，降级到后续检查项）

### 3.2 非交互式工作流保护

| 场景 | 行为 | 说明 |
|------|------|------|
| `kyb --help` / `kyb -h` | 不触发启动锁 | 新用户查看帮助不受阻碍 |
| `kyb --version` / `kyb -v` | 不触发启动锁 | 版本查询始终可用 |
| `kyb <subcommand>` | 正常触发 | 标准流程 |
| 非 TTY（管道/SSH exec/cron） | 自动跳过 | `$stdin.tty?` 为 false 时不阻塞 |
| CI 环境 | 跳过（推荐设 `KYB_STARTUP_BYPASS=true`） | 显式确认 |

**非 TTY 跳过理由**：非交互式场景下无法展示同意提示，直接阻断会破坏 cron/CI/远程执行。跳过不等于放弃同意——CI 应通过环境变量显式确认。

**实现位置**：启动锁在 `Kyb::CLI.dispatch` 入口插入，但 `--help`/`--version` 不经过锁。

```ruby
def self.dispatch(argv)
  # --help 和 --version 不触发启动锁
  if argv.any? { |a| ['--help', '-h', '--version', '-v'].include?(a) }
    return super
  end

  Kyb::StartupLock.check
  super
end
```

### 3.3 同意文案

```
╔══════════════════════════════════════════════════════════╗
║                    kyb 启动确认                          ║
╠══════════════════════════════════════════════════════════╣
║ kyb 是一个 Docker 沙箱管理工具，可以：                    ║
║  • 创建/删除 Docker 容器                                 ║
║  • 在容器中执行命令                                      ║
║  • 管理容器生命周期（启动/停止/删除）                     ║
║                                                          ║
║ 继续使用即表示您了解以上行为。                            ║
║                                                          ║
║ 输入 yes 确认，或输入任意内容取消。                      ║
║ 如需在 CI/非交互环境中跳过，设置环境变量：                ║
║   export KYB_STARTUP_BYPASS=true                          ║
║ 或通过配置文件永久禁用：                                  ║
║   # ~/.config/kyb/config.yml                              ║
║   startup_lock:                                           ║
║     enabled: false                                        ║
╚══════════════════════════════════════════════════════════╝
```

**交互行为**：
- 输入 `yes` → 写入 `.consent`，继续执行
- 输入其他内容（如 `no`、`n`） → 不退出，提示重试
- Ctrl+D (EOF) → exit 1（用户放弃）
- 提示中包含 `KYB_STARTUP_BYPASS` 和 `config.yml` 禁用方法

### 3.4 配置项

在 `~/.config/kyb/config.yml` 中新增（可选）：

```yaml
# 启动锁配置（完全可选）
startup_lock:
  enabled: true          # 设为 false 完全禁用启动锁
                         # 不配置此字段 = 默认启用
```

`KYB_STARTUP_BYPASS` 环境变量：
- 设为 `true` 时自动通过启动锁（并写入 `.consent`）
- 严格布尔语义：只有 `KYB_STARTUP_BYPASS=true` 才放行（空值/`false`/其他值无效）
- 在 CI 环境中最有用
- 单次生效：自动写入 `.consent` 后，后续运行无需再设置

### 3.5 不自毁原则

启动锁代码必须遵循以下约束（参考 infra-boss P0 自保机制）：

1. **不修改原有业务逻辑** — `startup_lock()` 只有 return 和 exit 两种出口，不改变任何全局状态
2. **异常安全** — 如果 `.consent` 文件读取失败（权限问题等），**放行而非阻止**（fail open）。kyb 的功能完整性优先于启动锁
3. **不依赖外部服务** — 启动锁只检查本地文件和环境变量，不请求网络
4. **不自锁** — 如果 `startup_lock` 代码本身抛出异常，捕获后放行。不能因为启动锁 bug 导致 kyb 完全不可用

```ruby
def self.check
  check_impl
rescue StandardError => e
  $stderr.puts "kyb: warning: startup lock check failed (#{e.message}), proceeding anyway"
  # fail open — 启动锁故障不阻塞 kyb 使用
end
```

### 3.6 测试隔离：依赖注入

所有函数使用依赖注入参数，避免测试污染真实 home 目录和环境：

```ruby
# 方法签名
def self.check(
  consent_path: File.expand_path('~/.config/kyb/.consent'),
  input_io: $stdin,
  env: ENV
)
```

```ruby
# 测试示例
def test_consent_file_exists
  Dir.mktmpdir do |tmpdir|
    consent_file = File.join(tmpdir, '.consent')
    File.write(consent_file, "kyb-consent:v1\nconsented:2026-05-25T00:00:00+00:00")

    result = Kyb::StartupLock.check(
      consent_path: consent_file,
      input_io: StringIO.new,
      env: {}
    )

    assert result  # 静默通过
  end
end
```

---

## 4. 测试方案

### 4.1 单元测试

在 `test/` 下新增 `test_startup_lock.rb`：

| # | 测试场景 | 注入参数 | 期望行为 |
|---|---------|---------|---------|
| 1 | `.consent` 存在且内容合法 | `consent_path` → 合法 `.consent` | 通过 |
| 2 | `.consent` 存在但内容为空 | `consent_path` → 空文件 | 降级到下一步 |
| 3 | `.consent` 存在但版本不匹配 | `consent_path` → v2 文件 | 降级到下一步 |
| 4 | `.consent` 不存在，`KYB_STARTUP_BYPASS=true` | `env: { 'KYB_STARTUP_BYPASS' => 'true' }` | 写入 `.consent`，通过 |
| 5 | `.consent` 不存在，`KYB_STARTUP_BYPASS=false` | `env: { 'KYB_STARTUP_BYPASS' => 'false' }` | 降级到下一步 |
| 6 | `.consent` 不存在，config 禁用 | `config_loader` → `{ 'enabled' => false }` | 通过 |
| 7 | `.consent` 不存在，非 TTY | `input_io: StringIO.new` | 自动跳过，通过 |
| 8 | `.consent` 不存在，输入 yes | `input_io` (tty, 回复 "yes") | 写入 `.consent`，通过 |
| 9 | `.consent` 不存在，输入 no | `input_io` (tty, 回复 "no") | 提示重试，不 exit |
| 10 | `.consent` 不存在，Ctrl+D | `input_io` (tty, gets → nil) | exit 1 |
| 11 | `--help` 不触发启动锁 | `argv: ['--help']` | 不调 startup_lock |
| 12 | `--version` 不触发启动锁 | `argv: ['--version']` | 不调 startup_lock |

### 4.2 集成测试

| # | 测试场景 | 命令 | 期望行为 |
|---|---------|------|---------|
| 1 | 全新环境 | `kyb ps` | 打印启动确认提示 |
| 2 | 同意后 | `kyb ps`（第二次） | 直接显示容器列表 |
| 3 | CI 环境 | `KYB_STARTUP_BYPASS=true kyb build` | 不提示，直接执行 |
| 4 | 禁用启动锁 | 配置 `enabled: false` | 不提示，直接执行 |
| 5 | 非 TTY | `echo "kyb ps" \| ssh server` | 不阻塞，直接执行 |

### 4.3 测试命令

```bash
# 运行全部启动锁测试
ruby -Itest test/test_startup_lock.rb

# 清理测试产生的 .consent 文件
rm -f ~/.config/kyb/.consent
```

---

## 5. 实现计划

### 5.1 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `lib/kyb/startup_lock.rb` | **新增** | 启动锁模块，包含 `check` 方法 |
| `lib/kyb/cli.rb` | **修改** | 在 `dispatch` 调用 `Kyb::StartupLock.check`，排除 `--help`/`--version` |
| `test/test_startup_lock.rb` | **新增** | 启动锁测试（依赖注入，不写真实 home） |
| `docs/infra/designs/kyb-startup-lock.md` | 本文件 | 设计方案（Round 2） |
| `README.md` | **修改** | 新增 "First Run Consent" 小节 |

### 5.2 实施步骤

1. 设计方案 10 人审查通过后合并
2. 实现 `lib/kyb/startup_lock.rb`
3. 在 `lib/kyb/cli.rb` 中插入调用（排除 `--help`/`--version`）
4. 编写测试，覆盖所有场景（依赖注入，不写真实 home）
5. 手动测试：清理 `.consent` 后运行 `kyb ps` 验证
6. 更新 README.md 添加 "First Run Consent" 小节
7. MR → CI 绿 → 合入 master

### 5.3 向后兼容

- 已在使用 kyb 的用户：升级后首次运行会触发同意提示，同意后生成 `.consent`，后续无变化
- `.consent` 文件不纳入版本控制（在 `~/.config/kyb/` 下，不在项目目录内）
- 不改变任何现有命令的行为逻辑
- `kyb --help` 和 `kyb --version` 在未同意时也可使用
- 非 TTY 环境自动跳过，不影响 cron/SSH exec 工作流

---

## 6. Documentation

### 6.1 README 更新

在 `README.md` 中新增 "First Run Consent" 小节，包含：

- 启动锁的目的说明（意外执行保护）
- 首次运行时的交互流程
- 如何通过环境变量 `KYB_STARTUP_BYPASS=true` 在 CI 中跳过
- 如何通过 `~/.config/kyb/config.yml` 永久禁用

```yaml
# ~/.config/kyb/config.yml
startup_lock:
  enabled: false
```

- 非 TTY 自动跳过行为说明
- `.consent` 文件位置和管理（`~/.config/kyb/.consent`）

---

## 7. 审查重点

Round 2 审查时请重点关注：

1. **方案 A' 是否覆盖所有场景** — 交互式 + env bypass + config disable + 非 TTY 自动跳过
2. **`.consent` 内容校验是否充分** — `kyb-consent:v1` 格式 + 版本锚定，防止空文件绕过
3. **`KYB_STARTUP_BYPASS` 布尔语义** — 只认 `true` 还是任意非空值放行？（当前：只认 `true`）
4. **非 TTY 跳过是否安全** — 自动跳过会不会引入安全隐患？（权衡：阻止 > 放行？）
5. **依赖注入设计是否合理** — `consent_path:`、`input_io:`、`env:` 参数签名是否覆盖测试需求？
6. **版本锚定策略** — `v1` 硬编码 vs 动态读取，未来升级路径
7. **`--help`/`--version` 排除** — 这两个命令排除后，用户能否绕过启动锁查看敏感信息？（只输出 CLI 使用说明，无敏感信息）

---

## 附录 A：相关 Issue

- [#169 DeepSeek API 代理设计](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/169) — 参考流程
- [#170 kyb 启动锁](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/170) — 本文对应 issue
