# kyb 启动锁设计方案

> Issue: https://git.leyantech.com/quick-n-dirty/kyb/-/issues/170
> Status: Phase 0 — 设计方案审查
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

### 方案 A：交互式同意（最简单）

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
- **容易被绕过** — 删除 `.consent` 文件即可重新触发，但也可通过 `echo yes | kyb` 跳过（实际上这意味着用户有意绕过，可接受）
- **非交互环境无法使用** — CI、管道、`kyb exec` 等场景无法输入 `yes`
- **无团队管控能力** — 无法为团队统一配置跳过
- **标记文件可被意外删除** — `kyb prune` 或其他清理操作可能误删

**适用场景**：个人开发环境，低风险。

---

### 方案 B：解锁码

**原理**：首次运行时要求输入解锁码。解锁码通过环境变量 `KYB_UNLOCK_KEY` 或在 `~/.config/kyb/config.yml` 中配置。匹配解锁码后生成 `.consent` 标记文件并通过。

**流程**：

```
# 首次运行（无解锁码）
$ kyb
==> kyb 需要解锁码才能使用。
==> 请输入解锁码（或设置 KYB_UNLOCK_KEY 环境变量）：

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
  return unless expected  # 未配置解锁码时默认放行？还是阻止？

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
- 安全性最高（相比方案 A）
- 可控性强 — 可随时更换解锁码
- 支持 CI/团队场景（环境变量传入）

**缺点**：
- **密钥管理负担** — 解锁码需要安全分发，丢失后无法使用 kyb
- **UX 差** — 每次新环境都需要找解锁码，增加摩擦
- **解锁码泄露** — 环境变量可能被进程列表、日志等泄露
- **复杂度提升** — 需要处理解锁码的配置、校验、错误提示

**适用场景**：需要管控谁可以使用 kyb 的团队环境。

---

### 方案 C：混合模式（推荐）

**原理**：结合方案 A 的交互式同意和方案 B 的解锁码机制，按优先级依次检查：

1. `~/.config/kyb/.consent` 存在 → 自动通过（已授权）
2. `KYB_UNLOCK_KEY` 环境变量匹配 → 自动通过并写入 `.consent`（CI/团队场景）
3. `~/.config/kyb/config.yml` 中 `startup_lock.enabled: false` → 自动通过（显式禁用）
4. 以上都不满足 → 打印警告，要求输入 `yes` 确认

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
║ 请输入 yes 确认（或设置 KYB_UNLOCK_KEY 跳过）：          ║
╚══════════════════════════════════════════════════════════╝
> yes
==> 感谢确认。继续执行...

# 场景 3：CI 环境（环境变量）
$ KYB_UNLOCK_KEY=xxx kyb build
（静默通过，并写入 .consent 供后续使用）

# 场景 4：显式禁用启动锁
$ cat ~/.config/kyb/config.yml
startup_lock:
  enabled: false
$ kyb
（静默通过）
```

**代码量**：约 40 行 Ruby

```ruby
def startup_lock
  consent_file = File.expand_path('~/.config/kyb/.consent')

  # 等级 1：已同意过
  return if File.exist?(consent_file)

  # 等级 2：解锁码匹配（自动同意并写入标记）
  unlock_key = ENV['KYB_UNLOCK_KEY']
  if unlock_key && !unlock_key.empty?
    File.write(consent_file, "unlocked:#{unlock_key}\n#{Time.now.iso8601}")
    return
  end

  # 等级 3：配置中显式禁用
  config = Kyb::Config.load rescue {}
  return unless config.dig('startup_lock', 'enabled') != false

  # 等级 4：交互式同意
  print_consent_notice
  input = $stdin.gets&.strip
  if input == 'yes'
    File.write(consent_file, "consented:#{Time.now.iso8601}")
  else
    Kyb.die('启动确认失败。设置 KYB_UNLOCK_KEY 或输入 yes 以继续。')
  end
end
```

**优点**：
- **覆盖所有场景** — 交互式 + CI + 团队，不留死角
- **渐进式** — 个人用同意，团队用解锁码，不需要则禁用
- **向后兼容** — 不配置任何东西的老用户不受影响（解锁码默认为空时只要求 `yes`）
- **单文件标记** — `.consent` 文件是唯一状态，删除后重新同意即可

**缺点**：
- 比方案 A 多 ~30 行代码
- 需要协调三个检查维度的优先级（但逻辑清晰，容易理解）

---

### 2.1 方案综合对比

| 维度 | 方案 A（交互式同意） | 方案 B（解锁码） | 方案 C（混合模式） |
|------|:---:|:---:|:---:|
| 代码量 | ~10 行 | ~30 行 | ~40 行 |
| 实现难度 | ★☆☆ | ★★☆ | ★★☆ |
| 安全性 | ★☆☆（信任标记文件） | ★★★（需知解锁码） | ★★☆（标记文件 + 可选解锁码） |
| 用户体验 | ★★☆（首次需交互） | ★☆☆（需要找码） | ★★★（按场景自适应） |
| CI 兼容性 | ★☆☆（需 echo yes 管道） | ★★★（环境变量） | ★★★（优先级 2 自动过） |
| 团队管控 | ★☆☆（无管控） | ★★★（可统一配码） | ★★☆（可选解锁码） |
| 维护成本 | ★☆☆（几乎零维护） | ★★★（需管理密钥） | ★★☆（解锁码可选） |
| 绕过难度 | ★☆☆（delete .consent） | ★★★（需知码） | ★★☆（介于 A/B 之间） |

---

## 3. 推荐方案：方案 C 详细设计

### 3.1 检查优先级

```
startup_lock()
  │
  ├─ [1] ~/.config/kyb/.consent 存在?
  │      ├─ yes → return（静默通过）
  │      └─ no  → 继续
  │
  ├─ [2] ENV['KYB_UNLOCK_KEY'] 非空?
  │      ├─ yes → 写入 .consent → return（静默通过）
  │      └─ no  → 继续
  │
  ├─ [3] config.yml startup_lock.enabled == false?
  │      ├─ yes → return（静默通过）
  │      └─ no  → 继续
  │
  └─ [4] 交互式提示
         ├─ yes → 写入 .consent → return（继续执行）
         └─ 其他 → exit 1（退出）
```

### 3.2 `.consent` 文件格式

```
consented:2026-05-25T10:30:00+08:00
```

或（通过解锁码自动同意时）：

```
unlocked:xxxx
2026-05-25T10:30:00+08:00
```

文件位置：`~/.config/kyb/.consent`
- 纯文本，一行或两行
- 第一行是标记类型 + 时间戳/解锁码摘要
- 不存储完整解锁码（避免泄露）
- 文件存在即视为已同意，**不校验内容**（简化逻辑，避免内容损坏导致锁死）

### 3.3 只在 `kyb` 主入口执行

启动锁只插入在 **顶层 CLI dispatch 入口**（`Kyb::CLI.dispatch`），具体位置：

```
Kyb::CLI.dispatch(argv)
  │
  ├─ startup_lock()  ← 在这里插入
  │
  ├─ ...原有 dispatch 逻辑...
  └─ ...
```

- `kyb --help` / `kyb help` — **需要触发**（新用户首先会看 help）
- `kyb --version` — **需要触发**（确认版本前先确认授权）
- `kyb init` — **需要触发**（首次配置 kyb 时正好顺便同意）
- `kyb onboard` — **需要触发**（引导流程中自带说明，启动锁作为前置）

**不触发启动锁的命令**（白名单）：
- 无（所有命令都经过 dispatch，统一检查）

### 3.4 配置项

在 `~/.config/kyb/config.yml` 中新增（可选）：

```yaml
# 启动锁配置（完全可选）
startup_lock:
  enabled: true          # 设为 false 完全禁用启动锁
                         # 不配置此字段 = 默认启用
```

`KYB_UNLOCK_KEY` 环境变量：
- 设置后自动通过启动锁（并写入 `.consent`）
- 在 CI 环境中最有用
- 不需要在 config.yml 中配置解锁码（避免密钥落入版本控制）

### 3.5 不自毁原则

启动锁代码必须遵循以下约束（参考 infra-boss P0 自保机制）：

1. **不修改原有业务逻辑** — `startup_lock()` 只有 return 和 die 两种出口，不改变任何全局状态
2. **异常安全** — 如果 `.consent` 文件读取失败（权限问题等），**放行而非阻止**（fail open）。kyb 的功能完整性优先于启动锁
3. **不依赖外部服务** — 启动锁只检查本地文件和环境变量，不请求网络
4. **不自锁** — 如果 `startup_lock` 代码本身抛出异常，捕获后放行。不能因为启动锁 bug 导致 kyb 完全不可用

```ruby
def startup_lock
  startup_lock_impl
rescue StandardError => e
  $stderr.puts "kyb: warning: startup lock check failed (#{e.message}), proceeding anyway"
  # fail open — 启动锁故障不阻塞 kyb 使用
end
```

---

## 4. 测试方案

### 4.1 单元测试

在 `test/` 下新增 `test_startup_lock.rb`：

| # | 测试场景 | 前置条件 | 期望行为 |
|---|---------|---------|---------|
| 1 | `.consent` 存在 | 创建 `.consent` 文件 | 静默通过 |
| 2 | `.consent` 不存在，无交互 | 无 `.consent`，`$stdin` 返回 nil | 退出码非 0，打印提示 |
| 3 | `.consent` 不存在，输入 yes | 无 `.consent`，`$stdin` 返回 "yes\n" | 创建 `.consent`，继续执行 |
| 4 | `.consent` 不存在，输入 no | 无 `.consent`，`$stdin` 返回 "no\n" | 退出码非 0 |
| 5 | `KYB_UNLOCK_KEY` 匹配 | 设置环境变量 | 静默通过，写入 `.consent` |
| 6 | `config.yml` 禁用 | `startup_lock.enabled: false` | 静默通过 |
| 7 | 异常安全 | `.consent` 目录不可写 | 打印警告，放行 |
| 8 | 空 `KYB_UNLOCK_KEY` | `KYB_UNLOCK_KEY=""` | 降级到交互式提示 |
| 9 | `--help` 触发启动锁 | 无 `.consent`，`kyb help` | 要求确认后再显示 help |

### 4.2 集成测试

| # | 测试场景 | 命令 | 期望行为 |
|---|---------|------|---------|
| 1 | 全新环境 | `kyb ps` | 打印启动确认提示 |
| 2 | 同意后 | `kyb ps`（第二次） | 直接显示容器列表 |
| 3 | CI 环境 | `KYB_UNLOCK_KEY=x kyb build` | 不提示，直接执行 |
| 4 | 禁用启动锁 | 配置 `enabled: false` | 不提示，直接执行 |

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
| `lib/kyb/startup_lock.rb` | **新增** | 启动锁模块，包含 `startup_lock` 方法 |
| `lib/kyb/cli.rb` | **修改** | 在 `dispatch` 方法开头调用 `Kyb::StartupLock.check` |
| `test/test_startup_lock.rb` | **新增** | 启动锁测试 |
| `docs/infra/designs/kyb-startup-lock.md` | 本文件 | 设计方案（审查中） |

### 5.2 实施步骤

1. 设计方案 10 人审查通过后合并
2. 实现 `lib/kyb/startup_lock.rb`
3. 在 `lib/kyb/cli.rb` 中插入调用
4. 编写测试，覆盖所有场景
5. 手动测试：清理 `.consent` 后运行 `kyb ps` 验证
6. MR → CI 绿 → 合入 master

### 5.3  向后兼容

- 已在使用 kyb 的用户：升级后首次运行会触发同意提示，同意后生成 `.consent`，后续无变化
- `.consent` 文件不纳入版本控制（在 `~/.config/kyb/` 下，不在项目目录内）
- 不改变任何现有命令的行为逻辑
- kyb 的 `--help` 输出在同意后正常显示

---

## 6. 审查重点

10 人审查时请重点关注：

1. **优先级顺序是否合理** — 等级 1（`.consent`） vs 等级 2（环境变量） vs 等级 3（配置禁用） vs 等级 4（交互）的顺序是否覆盖所有场景？
2. **fail open 原则是否安全** — 异常时放行是否会降低启动锁的价值？（权衡：启动锁故障不应该阻塞生产环境使用）
3. **解锁码方案是否过度设计** — 对于 kyb 这样的开发者工具，是否需要解锁码？还是纯交互式同意就足够了？
4. **`.consent` 文件路径** — `~/.config/kyb/.consent` 是否是最合适的位置？是否需要考虑 XDG 规范？
5. **不自毁约束是否充分** — 还有哪些边缘情况可能导致启动锁自毁？

---

## 附录 A：与 Issue #169 流程对比

| 阶段 | #169（DeepSeek 代理） | #170（启动锁） |
|------|----------------------|---------------|
| 等级 | META-INFRA（所有人断网） | L1（单一开发者） |
| 方案数量 | 5 个 | 3 个 |
| 审查轮次 | 4 轮 | 待定 |
| 代码量 | ~500 行 Go | ~40 行 Ruby |
| 风险等级 | 高 | 低 |

## 附录 B：相关 Issue

- [#169 DeepSeek API 代理设计](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/169) — 参考流程
- [#170 kyb 启动锁](https://git.leyantech.com/quick-n-dirty/kyb/-/issues/170) — 本文对应 issue
