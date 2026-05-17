# DID 命名统一与软隔离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 统一 `kyb did` 容器命名格式为 `did-<project>-<branch>-<name>`，添加 `KYB_BRANCH`/`KYB_DID` 环境变量和 `did_parent` label，实现容器列表软隔离和嵌套拦截。

**Architecture:** 5 个文件改动。`docker.rb` 注入新环境变量 → `cli/did.rb` 重写核心逻辑 → `cli/manage.rb` 更新级联清理 label → 测试覆盖新行为 → 文档同步。

**Tech Stack:** Ruby (minitest), Docker CLI

---

### Task 1: 注入 KYB_BRANCH 环境变量

**Files:**
- Modify: `lib/kyb/docker.rb:152`（`run` 方法内 `-e` 参数列表）
- Modify: `test/test_docker.rb`（run 测试覆盖）

- [ ] **Step 1: 在 `run` 方法中加 `KYB_BRANCH`**

在 `docker.rb` `run` 方法的 `-e` args 块中，紧跟 `KYB_PROJECT` 行之后加入：

```ruby
    args += ['-e', "KYB_BRANCH=#{branch}"]
```

位置在 `lib/kyb/docker.rb` 第 152 行 `args += ['-e', "KYB_PROJECT=#{project_name}"]` 之后。

- [ ] **Step 2: 写测试验证 `KYB_BRANCH` 出现在 run args**

在 `test/test_docker.rb` 中 `test_run_passes_tz_env_var` 后面追加：

```ruby
  def test_run_passes_kyb_branch_env_var
    wt_path = '/tmp/test-wt-branch'
    FileUtils.mkdir_p(wt_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(wt_path: wt_path))
    assert args.each_cons(2).any? { |f, v| f == '-e' && v == 'KYB_BRANCH=sandbox' },
           'expected -e KYB_BRANCH=sandbox'
  ensure
    FileUtils.rm_rf('/tmp/test-wt-branch')
  end
```

`default_run_kwargs` 用的 `Kyb::Container.new('niao', 'sandbox')`，所以 branch 是 `sandbox`。

- [ ] **Step 3: 跑测试**

```bash
ruby -Ilib -Itest test/test_docker.rb -n test_run_passes_kyb_branch_env_var
```

- [ ] **Step 4: Commit**

```bash
git add lib/kyb/docker.rb test/test_docker.rb
git commit -m "feat: inject KYB_BRANCH env var into kyb containers"
```

---

### Task 2: 重写 DID 容器创建逻辑

**Files:**
- Modify: `lib/kyb/cli/did.rb`
- Create: `test/test_did.rb`

- [ ] **Step 1: 写嵌套拦截测试**

`test/test_did.rb`:

```ruby
require_relative 'test_helper'

class DIDTest < Minitest::Test
  def test_did_create_refuses_nesting
    ENV['KYB_DID'] = 'inner'
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(['nested']) } }
  ensure
    ENV.delete('KYB_DID')
  end

  def test_did_create_refuses_when_no_project
    ENV.delete('KYB_PROJECT')
    ENV.delete('KYB_BRANCH')
    assert_raises(SystemExit) { capture_io { Kyb::CLI.did_create(['orphan']) } }
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
ruby -Ilib -Itest test/test_did.rb -n test_did_create_refuses_nesting
# 期待: SystemExit 没被 raise（did_create 还没有嵌套检查）
```

- [ ] **Step 3: 重写 `did_create` 核心逻辑**

完整替换 `lib/kyb/cli/did.rb`。改动点：

**a) 嵌套检查 + 环境检查：**
```ruby
  Kyb.die("DID nesting is not allowed (already inside a DID container)") if ENV['KYB_DID']
  project = ENV['KYB_PROJECT']
  branch  = ENV['KYB_BRANCH']
  Kyb.die("kyb did create must run inside a kyb container (KYB_PROJECT and KYB_BRANCH required)") unless project && branch
```

**b) 容器名改为 `did-<project>-<branch>-<name>`：**
```ruby
  name = args.first
  cname = "did-#{project}-#{branch}-#{name}"
```

**c) 全局冲突检测（查所有容器名）：**
```ruby
  all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
  Kyb.die("container '#{cname}' already exists") if all_names.include?(cname)
```

**d) Volume 名同步更改：**
```ruby
  volume = "#{cname}-worktree"
```

**e) 环境变量更新：**
```ruby
  run_args += ['-e', "KYB_PROJECT=#{name}"]
  run_args += ['-e', "KYB_BRANCH=#{branch}"]
  run_args += ['-e', "KYB_PARENT=#{parent}"]
  run_args += ['-e', "KYB_DID=#{name}"]
```

**f) Label 更新：**
```ruby
  run_args += ['--label', "did_parent=#{parent}"]
```

**g) docker cp —— 项目目录不受命名影响（项目路径用 KYB_PROJECT 的短名）：**
```ruby
  # 已有逻辑不需要改，KYB_PROJECT=name 用于指向 /home/dev/projects/<name>
```

完整 `did_create` 函数最终代码：

```ruby
  def did_create(args)
    Kyb.die("DID nesting is not allowed (already inside a DID container)") if ENV['KYB_DID']
    project = ENV['KYB_PROJECT']
    branch  = ENV['KYB_BRANCH']
    Kyb.die("kyb did create must run inside a kyb container (KYB_PROJECT and KYB_BRANCH required)") unless project && branch

    name = args.first
    cname = "did-#{project}-#{branch}-#{name}"
    all_names = `docker ps -a --format '{{.Names}}'`.lines.map(&:strip)
    Kyb.die("container '#{cname}' already exists") if all_names.include?(cname)

    parent = did_parent_name || 'host'
    volume = "#{cname}-worktree"

    system('docker', 'volume', 'create', volume) || Kyb.die("failed to create volume '#{volume}'")

    run_args = %w[docker run -d --name]
    run_args << cname
    run_args += ['--label', 'kyb=true']
    run_args += ['--label', "did_parent=#{parent}"]
    run_args += ['-e', "KYB_PROJECT=#{name}"]
    run_args += ['-e', "KYB_BRANCH=#{branch}"]
    run_args += ['-e', "KYB_PARENT=#{parent}"]
    run_args += ['-e', "KYB_DID=#{name}"]
    run_args += ['-e', "GITLAB_TOKEN=#{ENV['GITLAB_TOKEN']}"] if ENV['GITLAB_TOKEN']
    run_args += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

    run_args += ['-v', "#{volume}:/home/dev/projects/#{name}"]

    %w[kyb-gradle-cache kyb-maven-cache].each do |vol|
      system('docker', 'volume', 'create', vol, out: File::NULL) || Kyb.die("failed to create volume '#{vol}'")
    end
    run_args += ['-v', 'kyb-gradle-cache:/home/dev/.gradle']
    run_args += ['-v', 'kyb-maven-cache:/home/dev/.m2/repository']

    swift_cache = 'kyb-swift-cache'
    if `docker volume ls -q --filter name=^#{swift_cache}$`.strip == swift_cache
      run_args += ['-v', "#{swift_cache}:/home/dev/.local/swift"]
    end

    run_args += ['-v', '/var/run/docker.sock:/var/run/docker.sock']
    run_args += ['--hostname', cname]
    run_args << Kyb::Container::BASE_IMAGE

    puts "==> #{cname}: creating DID container (parent: #{parent})"
    system(*run_args) || Kyb.die('docker run failed')

    30.times do
      break if system('docker', 'exec', '-u', 'dev', cname,
                       'test', '-f', '/home/dev/.claude/settings.json',
                       out: File::NULL, err: File::NULL)
      sleep 0.5
    end

    ssh_dir = File.expand_path('~/.ssh')
    if File.directory?(ssh_dir)
      system('docker', 'cp', "#{ssh_dir}/.", "#{cname}:/home/dev/.ssh/")
    end

    gitconfig = File.expand_path('~/.gitconfig')
    if File.exist?(gitconfig) && !File.directory?(gitconfig)
      system('docker', 'cp', gitconfig, "#{cname}:/home/dev/.gitconfig")
    end

    kyb_config = File.expand_path('~/.config/kyb')
    if File.directory?(kyb_config)
      system('docker', 'cp', "#{kyb_config}/.", "#{cname}:/home/dev/.config/kyb/")
    end

    system('docker', 'exec', '-u', 'root', cname,
           'chown', '-R', 'dev:dev', '/home/dev/.ssh', '/home/dev/.gitconfig', '/home/dev/.config')

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ DID container ready! Container: #{cname}"
  end
```

- [ ] **Step 4: 更新 `did_rm`**

已创建的 DID 容器名格式变了，但 `did_rm` 的逻辑不变——它只关心 `did_parent=<cname>` label。需要更新的只是 volume 名格式:

```ruby
  def did_rm(args)
    name = args.first
    # 需要知道 project+branch 才能构造 cname。有两种方案：
    # 方案 A：从 args 直接构造（需要 project+branch，但 did_rm 不知道）
    # 方案 B：用 filter 查
    # 选 B：查找容器名匹配 did-*-*-<name> 的唯一一个
    candidates = `docker ps -a --format '{{.Names}}' --filter name=did-`.lines.map(&:strip).select { |n| n.end_with?("-#{name}") }
    if candidates.empty?
      puts "==> No DID container found matching '#{name}'"
      return
    end
    cname = candidates.first

    `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |child|
      puts "==> #{child}: removing child container"
      system('docker', 'rm', '-f', child)
    end

    Kyb::Docker.remove_container(cname)
    Kyb::Docker.volume_rm("#{cname}-worktree")

    puts "==> Done: #{cname} removed"
  end
```

- [ ] **Step 5: `did_rm` 标签验证**（标签行为由 Task 4 的集成式使用覆盖，无需单独单元测试）

- [ ] **Step 6: 跑测试**

```bash
ruby -Ilib -Itest test/test_did.rb
```

- [ ] **Step 7: Commit**

```bash
git add lib/kyb/cli/did.rb test/test_did.rb
git commit -m "feat: unify DID naming to did-<project>-<branch>-<name>"
```

---

### Task 3: 实现 `did ps` 软隔离

**Files:**
- Modify: `lib/kyb/cli/did.rb`（`did_ps` 方法）

- [ ] **Step 1: 更新 `did_ps` 支持 `--all` 参数**

`did` 入口增加 `--all` 解析：

```ruby
  def did(argv)
    show_all = argv.delete('--all') || argv.delete('-a')
    cmd = argv.first
    args = argv[1..] || []

    case cmd
    when 'create'
      Kyb.die("Usage: kyb did create <name>") unless args.first
      did_create(args)
    when 'rm'
      Kyb.die("Usage: kyb did rm <name>") unless args.first
      did_rm(args)
    when 'ps', 'ls'
      did_ps(show_all: show_all)
    else
      did_help
    end
  end
```

- [ ] **Step 2: 实现 `did_ps` 隔离逻辑**

```ruby
  def did_ps(show_all: false)
    # Determine filter base
    if show_all
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    elsif ENV['KYB_DID']
      # Inside a DID container — show siblings (same parent)
      parent = ENV['KYB_PARENT']
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter label=did_parent=#{parent} 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    elsif ENV['KYB_PROJECT']
      # Inside a regular kyb container — show children
      my_name = `hostname`.strip
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter label=did_parent=#{my_name} 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    else
      # On host — show all
      list = `docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter 'name=did-' 2>/dev/null`
              .lines.map { |l| l.strip.split("\t", 3) }
    end

    if list.empty?
      puts 'No DID containers.'
      return
    end

    printf "%-28s  %-24s  %s\n", 'DID NAME', 'STATUS', 'PARENT'
    list.each do |name, status, ports|
      label = `docker inspect --format '{{index .Config.Labels "did_parent"}}' #{name}`.strip rescue ''
      parent = label.empty? ? '' : "parent: #{label}"
      printf "%-28s  %-24s  %s\n", name.sub(/^did-/, ''), status, parent
    end
  end
```

- [ ] **Step 3: 更新帮助文本**

`did_help` 中 ps 命令说明加 `[--all]`：

```ruby
        ps, ls [--all]         List DID containers (--all: show all, default: show siblings)
```

- [ ] **Step 4: 软隔离测试**（CLI dispatch 测试已验证 `--all` 参数解析，容器隔离逻辑依赖 Docker CLI filter，由集成时验证）

- [ ] **Step 5: 跑测试**

```bash
ruby -Ilib -Itest test/test_did.rb
ruby -Ilib -Itest test/test_cli.rb
```

- [ ] **Step 6: Commit**

```bash
git add lib/kyb/cli/did.rb test/test_did.rb
git commit -m "feat: add did ps soft isolation with --all flag"
```

---

### Task 4: 更新级联清理 label

**Files:**
- Modify: `lib/kyb/cli/manage.rb`

- [ ] **Step 1: `rm` 方法中替换 `kyb-did=` → `did_parent=`**

`manage.rb:75`：

```ruby
    `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{c.name}`.lines.map(&:strip).each do |did_child|
```

- [ ] **Step 2: `prune` 方法中替换**

`manage.rb:108`：

```ruby
        `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |did_child|
```

- [ ] **Step 3: Commit**

```bash
git add lib/kyb/cli/manage.rb
git commit -m "fix: update cascade cleanup to use did_parent label"
```

---

### Task 5: 更新 CLI dispatch 测试

**Files:**
- Modify: `test/test_cli.rb`

- [ ] **Step 1: 更新 `test_did_create` 断言值传递不变**

`test_cli.rb:219-223` 现有测试验证 `did_create(['mybox'])`，这层 dispatch 接口不变（`create` 子命令的参数仍然是 `['mybox']`），所以无需改动当前测试。

加 `--all` 标志的 dispatch 测试：

```ruby
  def test_did_ps_all
    cmd, _args = dispatch('did', 'ps', '--all')
    assert_equal :did_ps, cmd
  end
```

- [ ] **Step 2: 跑测试**

```bash
ruby -Ilib -Itest test/test_cli.rb -n test_did_ps_all
```

- [ ] **Step 3: Commit**

```bash
git add test/test_cli.rb
git commit -m "test: add did ps --all dispatch test"
```

---

### Task 6: 更新文档

**Files:**
- Modify: `docs/kyb-did.md`

- [ ] **Step 1: 更新容器规范表**

| 属性 | 值 |
|------|-----|
| 命名 | `did-<project>-<branch>-<name>` |
| 标签 | `did_parent=<parent-container-name>` |
| 环境变量 | `KYB_PROJECT=<name>` `KYB_BRANCH=<branch>` `KYB_PARENT=<parent>` `KYB_DID=<name>` |

- [ ] **Step 2: 更新创建流程**

`kyb did create` 流程图中加入嵌套检查、冲突检测的步骤。

- [ ] **Step 3: 新增"行为约束"章节**

描述：
- 禁止二级嵌套
- 全局容器名冲突检测
- `did ps` 软隔离规则

- [ ] **Step 4: Commit**

```bash
git add docs/kyb-did.md
git commit -m "docs: update kyb-did.md with new naming and constraints"
```

---

## 验证清单

最终确认所有测试通过：

```bash
ruby -Ilib -Itest test/test_cli.rb
ruby -Ilib -Itest test/test_did.rb
ruby -Ilib -Itest test/test_docker.rb
ruby -Ilib -Itest test/test_container.rb
ruby -Ilib -Itest test/test_parser.rb
```

所有测试通过后执行最终验证性 commit：

```bash
git log --oneline -10
# 确认所有 6 个 commit 在链上
```
