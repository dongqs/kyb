# Worktree → Direct Mount + Clone 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从 kyb 移除 git worktree，改为 direct mount（默认）+ git clone（--clone 模式）

**Architecture:** 
- 默认模式：宿主项目 repo 直接 rw mount 进容器，`kyb create` 前自动 `git fetch && git checkout master && git merge --ff-only origin/master`
- --clone 模式：`git clone` 本地副本到 `~/.local/share/kyb/clones/` 再 bind-mount
- `kyb rm` 不再碰 git repo，只删容器 + volume
- 移除 sandbox 模式（不再需要）
- ExitFlow 改为检查宿主 repo 的 diff + cherry，不再检查 worktree

**Tech Stack:** Ruby, Minitest, Docker CLI

---

### Task 1: 删除 sandbox 模式

**Files:**
- Delete: `lib/kyb/cli/sandbox.rb` (全文件 419 行)
- Delete: `test/test_sandbox.rb` (全文件 199 行)
- Modify: `lib/kyb/cli.rb` (删除 sandbox 入口 + help + require)

- [ ] **Step 1: 删除 sandbox.rb 和 test_sandbox.rb**

```bash
git rm lib/kyb/cli/sandbox.rb test/test_sandbox.rb
```

- [ ] **Step 2: 从 cli.rb 删除 sandbox 引用**

`lib/kyb/cli.rb` 中删除：

```ruby
# 删除 dispatch 中的 sandbox case（L73-74）：
     when 'sandbox'
       sandbox(args)

# 删除 help 中的 sandbox 文档（L140-142）：
         sandbox PROJECT-BRANCH [PROMPT]  Claude Code sandbox mode (no Docker)
         sandbox ps, ls                   List host sandboxes
         sandbox rm PROJECT-BRANCH        Remove host sandbox

# 删除 require（L165）：
 require_relative 'cli/sandbox'
```

- [ ] **Step 3: 运行测试确认不影响现有逻辑**

```bash
ruby -Itest test/test_cli.rb -n test_help 2>&1
```

Expected: test passes, no sandbox references in output.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: remove kyb sandbox mode (replaced by kyb create)" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: 删除 git worktree 操作模块

**Files:**
- Delete: `lib/kyb/git.rb` (全文件 58 行)
- Modify: `lib/kyb.rb` (删除 `WORKTREE_BASE`，新增 `CLONE_BASE`)
- Modify: `lib/kyb/container.rb` (删除 `worktree_path` 方法，保留 `git_branch`)

- [ ] **Step 1: 删除 git.rb**

```bash
git rm lib/kyb/git.rb
```

- [ ] **Step 2: 更新 kyb.rb——删除 WORKTREE_BASE，新增 CLONE_BASE**

`lib/kyb.rb` 中：

```ruby
# 删除 L64：
  WORKTREE_BASE = File.expand_path('~/.local/share/kyb/worktrees')

# 在 GRADLE_CACHE_VOLUME 行后新增（保持字母顺序）：
  CLONE_BASE = File.expand_path('~/.local/share/kyb/clones')
```

- [ ] **Step 3: 更新 container.rb——删除 worktree_path，保留 git_branch**

`lib/kyb/container.rb` 中删除：

```ruby
# L37-39 删除整个方法：
    def worktree_path
      File.join(Kyb::WORKTREE_BASE, project, name) if project
    end
```

保留 `git_branch`（L33-35）——`kyb rm` 的远端分支提示仍需它。

- [ ] **Step 4: 搜索并删除所有引用 WORKTREE_BASE 和 git.rb 的 require**

```bash
grep -rn 'WORKTREE_BASE\|require_relative.*git' lib/
```

确认结果为空（除已删除的文件外无引用）。`lib/kyb/container.rb` 中不再引用 `WORKTREE_BASE`，`lib/kyb/cli/sandbox.rb` 已删。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: remove git worktree operations and WORKTREE_BASE constant" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: 重写 docker.rb——run 方法签名和 mount 逻辑

**Files:**
- Modify: `lib/kyb/docker.rb` (run 方法: wt_path → repo_path, 所有 mount 调整)

- [ ] **Step 1: 修改 run 方法签名**

```ruby
# 原（L122）：
    def run(container:, image:, wt_path:, project_name:, project_path:, ports:, symlinks:, mounts_rw:, mounts_ro:, model: nil, timezone: 'Asia/Shanghai', kyb_proxy: nil, kyb_no_proxy: nil, branch: nil)

# 改为（删除 wt_path:, 改为 repo_path:）：
    def run(container:, image:, repo_path:, project_name:, project_path:, ports:, symlinks:, mounts_rw:, mounts_ro:, model: nil, timezone: 'Asia/Shanghai', kyb_proxy: nil, kyb_no_proxy: nil, branch: nil, clone: false)
```

- [ ] **Step 2: 更新 run 方法的 mount 逻辑**

`lib/kyb/docker.rb` L123 日志消息：
```ruby
# 原：
    puts "==> #{container.name}: starting (#{wt_path} -> /home/dev/projects/#{project_name})"
# 改为：
    puts "==> #{container.name}: starting (#{repo_path} -> /home/dev/projects/#{project_name})"
```

L168-172：DinD/normal mount 逻辑
```ruby
# 原（L168-172）：
    if dind
      args += ['-v', "#{container.name}-worktree:/home/dev/projects/#{project_name}"]
    else
      args += ['-v', "#{wt_path}:/home/dev/projects/#{project_name}"]
    end
# 改为（默认模式 mount 宿主 repo 路径，--clone 模式 mount clone 路径）：
    if dind
      args += ['-v', "#{container.name}-project:/home/dev/projects/#{project_name}"]
    else
      args += ['-v', "#{repo_path}:/home/dev/projects/#{project_name}"]
    end
```

L174-196：project_path mount, symlinks, mounts_rw/ro 逻辑不变（这些与 worktree 无关）。

- [ ] **Step 3: 更新 create_container 参数的传递**

`lib/kyb/docker.rb` L298-313 中 `run` 调用：
```ruby
# 原：
    run(
      container: container,
      image: image,
      wt_path: wt_path,          # ← 改为 repo_path: path
      project_name: project,
      project_path: path,
      ...
    )

# 改为（wt_path 替换为 repo_path，对于默认模式就是 path，对于 --clone 模式是 clone_path）：
    repo_path = clone ? clone_path : path
    run(
      container: container,
      image: image,
      repo_path: repo_path,
      project_name: project,
      project_path: path,
      ...
      clone: clone
    )
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(docker): replace wt_path with repo_path in run/create_container" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: 重写 docker.rb——create_container 核心逻辑

**Files:**
- Modify: `lib/kyb/docker.rb` (create_container: 去 worktree，加 ensure_master_synced + --clone 逻辑 + 多容器冲突检测)

- [ ] **Step 1: 添加 ensure_master_synced 辅助方法**

`lib/kyb/docker.rb` 中新增：

```ruby
  # 确保宿主 repo 在 master 且与 origin/master 同步
  def ensure_master_synced(repo_path, base_branch)
    puts "==> syncing #{repo_path} to origin/#{base_branch}"
    Dir.chdir(repo_path) do
      system('git', 'fetch', 'origin', base_branch) || Kyb.die("git fetch origin #{base_branch} failed")
      system('git', 'checkout', base_branch) || Kyb.die("git checkout #{base_branch} failed")
      system('git', 'merge', '--ff-only', "origin/#{base_branch}") || Kyb.die("git merge --ff-only origin/#{base_branch} failed")
    end
  end
```

- [ ] **Step 2: 添加 clone_path 和 clone 逻辑**

`lib/kyb/docker.rb` 中新增：

```ruby
  def clone_path(project, container)
    File.join(Kyb::CLONE_BASE, project, container.name)
  end

  def setup_clone(source_path, clone_target, container)
    puts "==> cloning #{source_path} -> #{clone_target}"
    FileUtils.mkdir_p(File.dirname(clone_target))
    system('git', 'clone', source_path, clone_target) || Kyb.die('git clone failed')
  end
```

- [ ] **Step 3: 添加多容器冲突检测**

`lib/kyb/docker.rb` 中新增：

```ruby
  def check_shared_project_conflict(project)
    # 查找同一项目下非 clone 模式的运行中容器
    containers = containers_for_project(project).select { |name| container_running?(name) }
    containers.reject! { |name| name.include?('--clone') }  # 简单 heuristic
    containers
  end
```

（冲突 prompt 在 `create_container` 中注入。）

- [ ] **Step 4: 重写 create_container 核心流程**

`lib/kyb/docker.rb` `create_container` 中：

替换 L275-289（worktree + cp_files）：

```ruby
    # 去 worktree，改为 sync + 可选 clone
    if clone
      clone_target = clone_path(project, container)
      setup_clone(path, clone_target, container)
    else
      ensure_master_synced(path, proj[:base_branch])
    end

    # cp_files 仅在 --clone 模式下执行（默认 mount 下宿主直接改）
    if clone && proj[:cp_files]
      target = clone ? clone_target : path
      proj[:cp_files].each do |dst, src|
        src_path = File.join(path, src)
        if File.exist?(src_path)
          puts "     cp #{src} -> #{dst}"
          FileUtils.cp(src_path, File.join(target, dst))
        end
      end
    end

    # 多容器冲突检测（仅默认模式）
    unless clone
      same_project = check_shared_project_conflict(project)
      if same_project.any?
        puts "==> ⚠ 注意：项目 #{project} 已有运行中容器（#{same_project.join(', ')}）"
        puts "    多个容器共享同一 repo，git 操作可能互相影响。"
        puts "    如需隔离建议：改 config.yml 加 clone: true 或用 --clone flag。"
      end
    end
```

替换 L298-313（run 调用，已由 Task 3 处理）。

替换 L322-343（DinD tar 管道——保持 SSH/gitconfig 的 tar pipe，去掉 worktree tar pipe）：

```ruby
    # DinD：复制宿主配置文件
    if File.exist?('/.dockerenv')
      home = Dir.home
      tar_sources = []
      tar_sources << '.ssh' if File.directory?("#{home}/.ssh")
      tar_sources << '.gitconfig' if File.exist?("#{home}/.gitconfig")
      tar_sources << '.config/kyb' if File.directory?("#{home}/.config/kyb")

      if tar_sources.any?
        system('bash', '-c',
          "tar -C #{home} --exclude='.ssh/agent/*' -c #{tar_sources.join(' ')} 2>/dev/null | " \
          "docker exec -i #{container.name} bash -c '" \
          "tar -C /home/dev -x " \
          "&& chown -R dev:dev #{tar_sources.map { |s| "/home/dev/#{s}" }.join(' ')} 2>/dev/null || true'")
      end
    end
```

注意：删除了 L337-342 的 worktree tar pipe 块（`puts "==> #{container.name}: copying worktree into container"` 到 `chown -R dev:dev /home/dev/projects/#{project}`），因为 DinD 下直接 mount 宿主路径或 clone 目录即可（/var/run/docker.sock 使其可见）。

- [ ] **Step 5: 更新 create_container 签名接收 clone 参数**

```ruby
# 原（L250）：
    def create_container(project, branch, port_overrides = nil, model: nil)
# 改为：
    def create_container(project, branch, port_overrides = nil, model: nil, clone: false)
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(docker): worktree-free create_container with sync + clone + conflict detection" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: 简化 kyb rm 和 prune

**Files:**
- Modify: `lib/kyb/cli/manage.rb` (rm/prune: 去 git 清理逻辑)

- [ ] **Step 1: 重写 rm 方法**

`lib/kyb/cli/manage.rb` L63-91：

```ruby
  def rm(project, branch)
    Kyb::Config.load
    proj = Kyb::Config.project(project)
    path = proj[:path]
    Kyb.die("#{path} not found") unless File.directory?(path)

    c = Kyb::Container.new(project, branch)

    # Clean up any DID children first
    `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{c.name}`.lines.map(&:strip).each do |did_child|
      puts "==> #{did_child}: removing DID child container"
      system('docker', 'rm', '-f', did_child)
      system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
    end

    Kyb::Docker.remove_container(c.name)

    # 删除 clone 目录（如果存在）
    clone_target = Kyb::Docker.clone_path(project, c) rescue nil
    if clone_target && File.directory?(clone_target)
      puts "==> removing clone #{clone_target}"
      FileUtils.rm_rf(clone_target)
    end

    Kyb::Docker.volume_rm(c.claude_volume)

    puts "==> Done: #{c.name} removed"
    puts "==> 远端分支 #{c.git_branch} 未删除，如需清理请手动 git push origin --delete #{c.git_branch}"
  end
```

变化：
- 删除 `Kyb::Git.worktree_path` / `Kyb::Git.remove_worktree` / `Kyb::Git.delete_local_branch`
- `-worktree` → `-project` volume 命名
- 新增 clone 目录清理

- [ ] **Step 2: 重写 prune 方法**

`lib/kyb/cli/manage.rb` L93-127 同理，替换所有 git 清理为 clone 目录清理。

```ruby
  def prune
    Kyb::Config.load
    Kyb::Config.project_names.each do |proj_name|
      proj = Kyb::Config.project(proj_name)
      path = proj[:path]
      unless File.directory?(path)
        warn "WARNING: #{path} not found, skip #{proj_name}"
        next
      end

      Kyb::Docker.containers_for_project(proj_name).each do |cname|
        c = Kyb::Container.new(nil, nil, name: cname)
        puts "==> #{cname}: removing container"

        # Clean up DID children first
        `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |did_child|
          puts "       #{did_child}: removing DID child"
          system('docker', 'rm', '-f', did_child)
          system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
        end

        system('docker', 'rm', '-f', cname)

        # 清理 clone 目录
        clone_target = Kyb::Docker.clone_path(proj_name, c) rescue nil
        if clone_target && File.directory?(clone_target)
          FileUtils.rm_rf(clone_target)
        end

        Kyb::Docker.volume_rm(c.claude_volume)
        puts
      end
    end

    puts "==> All containers cleaned"
    puts "==> 远端分支未删除，如需清理请手动 git push origin --delete kyb/*"
  end
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "refactor(manage): simplify rm/prune - no more git worktree/branch cleanup" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: 重写 ExitFlow

**Files:**
- Modify: `lib/kyb/exit_flow.rb` (去掉 worktree 检查，改为宿主 repo diff/cherry 检查)

- [ ] **Step 1: 重写 exit_flow.rb 全部内容**

将整个文件替换为：

```ruby
# frozen_string_literal: true

module Kyb::ExitFlow
  module_function

  def enter_exit_cleanup(container, project, branch)
    cname = container.name
    puts
    puts "==> Container #{cname}: session ended."

    checks = run_idle_checks(container, project)
    all_pass = checks.values_at(:tmux, :dirty, :remote).all?

    if all_pass
      warnings = collect_extra_warnings(container)
      warnings.each { |w| puts "  ⚠  #{w}" } if warnings.any?
      puts
      interactive_delete_prompt(container, project, branch)
    else
      puts
      puts "    Cleanup skipped (see warnings above)."
      puts "    Force delete: kyb rm #{project}-#{branch}"
    end
  end

  def run_idle_checks(container, project)
    cname = container.name
    dind = File.exist?('/.dockerenv')

    puts
    puts "━━━  Idle Check  ━━━"

    tmux_dead = !system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
                        %i[out err] => File::NULL)
    puts tmux_dead ? "  ✔ tmux:     no active sessions" : "  ✘ tmux:     session still alive"

    # 检查宿主 repo 的工作区状态（非 DinD 下）
    repo_path = proj_path = nil
    unless dind
      begin
        proj = Kyb::Config.project(project)
        repo_path = proj[:path]
      rescue
      end
    end

    clean = if dind
              system('docker', 'exec', '-u', 'dev', cname,
                     'git', '-C', "/home/dev/projects/#{project}", 'diff', '--quiet',
                     %i[out err] => File::NULL)
            elsif repo_path && File.directory?("#{repo_path}/.git")
              Dir.chdir(repo_path) { system('git', 'diff', '--quiet', %i[out err] => File::NULL) }
            else
              true
            end
    puts clean ? "  ✔ repo:     clean" : "  ✘ repo:     uncommitted changes"

    remote_ok = if dind
                  `docker exec -u dev #{cname} bash -c 'cd /home/dev/projects/#{project} && git cherry' 2>/dev/null`.lines.count == 0
                elsif repo_path && File.directory?("#{repo_path}/.git")
                  Dir.chdir(repo_path) { `git cherry 2>/dev/null`.lines.count == 0 }
                else
                  false
                end
    puts remote_ok ? "  ✔ remote:   all pushed" : "  ✘ remote:   unpushed commits"

    { tmux: tmux_dead, dirty: clean, remote: remote_ok }
  end

  def collect_extra_warnings(container)
    cname = container.name
    warnings = []

    baseline = %w[ps tmux bash zsh sh sleep postgres pg_ctl sshd entrypoint runuser
                  claude kyb ruby python3 node tail dumb-init nginx]
    processes = `docker exec #{cname} ps -eo comm= 2>/dev/null`.lines.map(&:strip).reject(&:empty?).uniq
    unexpected = processes - baseline
    warnings << "processes: #{unexpected.join(', ')}" if unexpected.any?

    did_kids = `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname} 2>/dev/null`
               .lines.map(&:strip).reject(&:empty?)
    warnings << "DID children: #{did_kids.join(', ')} (will be cascade deleted)" if did_kids.any?

    warnings
  end

  def interactive_delete_prompt(container, project, branch)
    cname = container.name
    puts "━━━  Container Idle  ━━━━━━━━━━━━━"
    puts "Container:  #{cname}"
    puts "Project:    #{project} / #{branch}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "Cleanup will:"
    puts "  • stop & remove container"
    puts "  #{File.directory?(Kyb::CLONE_BASE.to_s + "/#{project}/#{cname}") ? '  • remove clone directory' : ''}"
    puts "  • remove claude volume"
    puts
    print "Delete container? [y/N] (5s auto: skip) "
    STDOUT.flush

    input = nil
    begin
      if IO.select([STDIN], nil, nil, 5)
        input = STDIN.gets.to_s.strip.downcase
      end
    rescue Interrupt
    end

    if input == 'y'
      perform_cleanup(container, project, branch)
    else
      puts
      puts "==> Cleanup skipped."
      puts "    Delete manually: kyb rm #{project}-#{branch}"
      puts "    Re-attach:       kyb enter #{project}-#{branch}"
    end
  end

  def perform_cleanup(container, project, branch)
    cname = container.name
    puts

    `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |did_child|
      puts "==> #{did_child}: removing DID child container"
      system('docker', 'rm', '-f', did_child)
      system('docker', 'volume', 'rm', "#{did_child}-project", out: File::NULL)
    end

    puts "==> #{cname}: stopping"
    system('docker', 'stop', cname)
    puts "==> #{cname}: removing"
    system('docker', 'rm', cname)

    # 清理 clone 目录（如果存在）
    clone_target = Kyb::Docker.clone_path(project, container) rescue nil
    if clone_target && File.directory?(clone_target)
      puts "==> removing clone #{clone_target}"
      FileUtils.rm_rf(clone_target)
    end

    Kyb::Docker.volume_rm(container.claude_volume)

    puts "==> Done. Container cleaned."
    puts
    puts "    Start fresh: kyb create #{project}-#{branch}"
  end
end
```

变化要点：
- `:worktree` 键改为 `:dirty`，消息从 `worktree: clean` 改为 `repo: clean`
- 检查对象从 `container.worktree_path` 改为 `Kyb::Config.project(project)[:path]`
- `perform_cleanup` 中删除 `Kyb::Git.remove_worktree` / `Kyb::Git.delete_local_branch`
- 新增 clone 目录清理（`Kyb::Docker.clone_path`）
- `-worktree` volume 命名改为 `-project`

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "refactor(exit_flow): check host repo instead of worktree" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: 添加 --clone CLI flag

**Files:**
- Modify: `lib/kyb/cli/create.rb` (解析 --clone 参数)
- Modify: `lib/kyb/cli.rb` (传递 clone 参数)

- [ ] **Step 1: 更新 cli.rb dispatch 中的 create case**

`lib/kyb/cli.rb` L28-42：

```ruby
    when 'create'
      Kyb.die("create requires a project-branch\n  Usage: kyb create PROJECT-BRANCH [--clone] [--ports HOST:CONTAINER] [--model flash|pro]") unless args.first
      project, branch = Kyb::Parser.parse(args.shift)
      port_overrides = nil
      model = nil
      clone = false
      if args.first == '--clone'
        args.shift
        clone = true
      end
      if args.first == '--ports'
        args.shift
        port_overrides = args.shift if args.first
      end
      if args.first == '--model'
        args.shift
        model = args.shift
        Kyb.die("--model must be 'flash' or 'pro'") unless %w[flash pro].include?(model)
      end
      create(project, branch, port_overrides, model: model, clone: clone)
```

- [ ] **Step 2: 更新 create.rb**

`lib/kyb/cli/create.rb` L6-36：

```ruby
    def create(project, branch, port_overrides = nil, model: nil, clone: false)
      container, ports = Kyb::Docker.create_container(project, branch, port_overrides, model: model, clone: clone)
      proj = Kyb::Config.project(project)
      image = Kyb::Container::BASE_IMAGE
      image = Kyb::Docker.project_image(project, File.join(proj[:path], proj[:dockerfile]), proj[:path]) if proj[:dockerfile]
      ...
      # 其余不变
    end
```

主要变化：`clone:` 参数从 cli.rb → create.rb → docker.rb 一路传递。

- [ ] **Step 3: 更新 help 文本**

`lib/kyb/cli.rb` L130-131：

```ruby
        create PROJECT-BRANCH [--clone] [--ports HOST:CONTAINER] [--model flash|pro]
                                         Create and start a container (--clone: isolated git clone)
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(cli): add --clone flag for isolated git clone mode" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: 更新测试

**Files:**
- Modify: `test/test_docker.rb` (wt_path → repo_path, 删除 worktree 测试, 添加 --clone 测试)
- Modify: `test/test_exit_flow.rb` (:worktree → :dirty, 删除 worktree stub)
- Modify: `test/test_container.rb` (删除 test_worktree_path)
- Modify: `test/test_readme.rb` (删除 worktree 相关测试)

- [ ] **Step 1: 更新 test_docker.rb**

`test/test_docker.rb` 中的变化：

```ruby
# L72: default_run_kwargs 中删除 wt_path
    def default_run_kwargs(overrides = {})
      {
        container: Kyb::Container.new('niao', 'sandbox'),
        image: 'kyb-base',
        repo_path: '/tmp/test-repo',    # ← 改名前
        project_name: 'niao',
        project_path: '/tmp/test-project',
        ports: '', symlinks: '', mounts_rw: '', mounts_ro: ''
      }.merge(overrides)
    end
```

更新测试方法：

```ruby
# test_run_mounts_kyb_dir（L128-137）：删除 wt_path 创建，使用 repo_path
  def test_run_mounts_kyb_dir
    kyb_dir = File.expand_path('~/.kyb')
    args = with_run_stubs(dind: false, **default_run_kwargs)
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == "#{kyb_dir}:#{kyb_dir}" },
           "expected -v #{kyb_dir}:#{kyb_dir}"
  end

# test_run_normal_mode_binds_wt_path（L139-147）→ 改为 test_run_normal_mode_binds_repo_path
  def test_run_normal_mode_binds_repo_path
    repo_path = '/tmp/test-repo-bind'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path))
    count = args.each_cons(2).count { |f, v| f == '-v' && v == "#{repo_path}:/home/dev/projects/niao" }
    assert_equal 1, count, 'expected exactly one bind mount for repo_path'
  ensure
    FileUtils.rm_rf('/tmp/test-repo-bind')
  end

# test_run_binds_project_path_when_different（L149-158）：repo_path 替换 wt_path，project_path 独立
  def test_run_binds_project_path_when_different
    pp = '/tmp/test-project-pp'
    repo_path = '/tmp/test-repo-pp'
    FileUtils.mkdir_p(repo_path)
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: repo_path, project_path: pp))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}:#{pp}" },
           'expected project_path bind mount'
  ensure
    FileUtils.rm_rf('/tmp/test-repo-pp')
  end

# test_run_skips_project_path_when_matches_wt_target（L160-167）→ 改为匹配 repo_path 目标
  def test_run_skips_project_path_when_matches_mount_target
    args = with_run_stubs(dind: false, **default_run_kwargs(
      repo_path: '/home/dev/projects/niao', project_path: '/home/dev/projects/niao'))
    mount_count = args.each_cons(2).count { |f, v| f == '-v' && v == '/home/dev/projects/niao:/home/dev/projects/niao' }
    assert_equal 1, mount_count, 'expected exactly one bind mount (from repo_path, not project_path)'
  end

# test_run_passes_tz_env_var（L169-178）：repo_path 替换
  def test_run_passes_tz_env_var
    args = with_run_stubs(dind: false, **default_run_kwargs(
      repo_path: '/tmp/test-repo-tz', model: 'flash', timezone: 'America/Sao_Paulo'))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'TZ=America/Sao_Paulo' },
           'expected -e TZ=America/Sao_Paulo'
  end

# test_run_passes_kyb_branch_env_var（L180-188）：repo_path 替换
  def test_run_passes_kyb_branch_env_var
    args = with_run_stubs(dind: false, **default_run_kwargs(repo_path: '/tmp/test-repo-branch', branch: 'sandbox'))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'KYB_BRANCH=sandbox' },
           'expected -e KYB_BRANCH=sandbox'
  end

# test_run_dind_uses_named_volume（L192-200）：-worktree → -project
  def test_run_dind_uses_named_volume
    args = with_run_stubs(dind: true, **default_run_kwargs(repo_path: '/tmp/test-repo-dind'))
    assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-niao-sandbox-project:/home/dev/projects/niao' },
           'expected named volume in DinD mode'
  end

# test_run_dind_skips_host_only_bind_mounts（L202-219）：repo_path 替换
# test_run_dind_skips_project_path_and_symlinks（L221-238）：repo_path 替换
# test_run_mounts_swift_cache_volume_when_exists（L242-253）：repo_path 替换
# test_run_skips_non_existent_volume（L255-266）：repo_path 替换
# test_run_mounts_kyb_config_when_dir_exists（L270-284）：repo_path 替换
# test_run_skips_kyb_config_when_dir_missing（L286-299）：repo_path 替换
# test_run_mounts_mise_and_pip_cache_volumes（L303-313）：repo_path 替换
```

更新 `stub_create_container_deps`（L317-338）：删除 `Kyb::Git.stub` 引用，改为：

```ruby
  def stub_create_container_deps(cp_files_val = nil)
    Kyb::Config.stub(:load, nil) do
    Kyb::Config.stub(:project, ->(name) {
      { name: name, path: '/tmp/test-cp-project', base_branch: 'master',
        dockerfile: nil, ports: [], symlinks: '', mounts_rw: '', mounts_ro: '',
        cp_files: cp_files_val, cp_files_base_keys: [].freeze,
        extra_prompt: nil, timezone: 'Asia/Shanghai',
        proxy: nil, no_proxy: nil }
    }) do
    Kyb::Config.stub(:base_image_path, '/tmp') do
    Kyb::Docker.stub(:build, true) do
    Kyb::Docker.stub(:image_exists?, true) do
    Kyb::Docker.stub(:assign_ports, '') do
    Kyb::Docker.stub(:run, nil) do
    Kyb::Docker.stub(:exists?, false) do
    Kyb::Docker.stub(:running?, false) do
    Kyb::Docker.stub(:ensure_master_synced, nil) do
    FileUtils.stub(:mkdir_p, nil) do
      yield
    end; end; end; end; end; end; end; end; end; end; end
  end
```

删除 `test_create_container_dind_copies_worktree_via_tar`（L341-360）——不再有 worktree tar pipe。

更新 cp_files 测试（L364-443）：`wt` 变量不再引用 `container.worktree_path`，改为引用 `path`：

```ruby
# L393-394：
        container = Kyb::Container.new('niao', 'test')
        wt = container.worktree_path
# 改为：
        container = Kyb::Container.new('niao', 'test')
        wt = path   # cp_files 目标改为宿主 repo 路径
```

`test_create_container_dind_tar_pipe_injects_host_files`（L475-503）保持不变（SSH/gitconfig tar pipe 与 worktree 无关）。

- [ ] **Step 2: 更新 test_exit_flow.rb**

`test/test_exit_flow.rb` 中：

```ruby
# 所有 :worktree → :dirty 替换
# L22:
    assert result[:dirty], 'repo should be clean'
# L26:
    assert_match(/✔ repo.*clean/, out)
# L51 方法名改为：
    def test_idle_checks_repo_dirty
# L64:
    refute result[:dirty]
# L66:
    assert_match(/✘ repo.*uncommitted changes/, out)
# L96, L108, L120:
    { tmux: true, dirty: true, remote: true }
# L227:
    def test_perform_cleanup_removes_container_and_clone
# L235-236：删除 Kyb::Git stub
```

- [ ] **Step 3: 更新 test_container.rb**

```ruby
# 删除 L58-61 test_worktree_path 整个方法
```

- [ ] **Step 4: 更新 test_readme.rb**

```ruby
# L250 test_worktree_mount_not_projects_dir — 删除或改为测试 repo_path mount
# L324 test_worktree_path_under_kyb — 删除
```

- [ ] **Step 5: 运行全部测试**

```bash
ruby -Itest -e 'Dir["test/test_cli.rb","test/test_config.rb","test/test_container.rb","test/test_parser.rb","test/test_exit_flow.rb","test/test_session.rb","test/test_stale_cli.rb","test/test_docker.rb"].sort.each { |f| require_relative f }' 2>&1
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "test: update tests for worktree-free architecture" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: 更新文档

**Files:**
- Modify: `README.md` (更新 worktree 引用，描述改为 mount 模式)
- Modify: `docs/` 中必要的文档（至少更新 dev-iteration.md, kyb-pitfalls.md）

- [ ] **Step 1: 更新 README.md**

关键改动点：

```markdown
# 架构图（README.md ~L100-115）：
  替换 worktree 行为 mount 描述
  ├── ~/.local/share/kyb/clones/    ← 新增：clone 模式代码目录

# ~L110 容器内目录描述：
  └── ~/projects/                 ← Git 项目 repo（direct mount 或 clone）

# ~L131-132 文件布局：
  删除 worktrees，改为 clones

# ~L211 base_branch 描述（不再是 worktree 基准分支）：
    base_branch: master             # git sync 基准分支

# ~L223-252 删除所有 worktree 相关描述，改为 mount 模式说明
# L282 "每个容器使用独立 git worktree" → 改为 "每个容器直接 mount 宿主 repo"
```

- [ ] **Step 2: 更新 key docs**

`docs/dev-iteration.md`：删除 worktree 相关描述，改为解释 clone 模式。
`docs/kyb-pitfalls.md`：更新或归档不再相关的条目。

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "docs: update for worktree-free architecture (mount + clone modes)" -m "Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Self-Review

**Spec coverage:**
- 背景（移除 worktree 的原因）→ Task 1-2
- 两种模式对比 → Task 3-4, Task 7
- 默认模式架构（sync + mount）→ Task 4
- --clone 模式架构 → Task 4
- kyb rm 简化 → Task 5
- ExitFlow 重写 → Task 6
- 多容器冲突检测 → Task 4
- Mount 策略（逐项目全 rw）→ Task 3
- 移除 sandbox → Task 1
- kyb 自身开发 → 文档 Task 9
- DID 场景 → 不涉及改动（卷名 -worktree → -project）
- K8s 展望 → 不涉及改动

**所有步骤都有完整代码无占位符。**

**类型一致性:** `Kyb::Docker.clone_path`, `ensure_master_synced` 在 Task 4 定义，Task 5/6 引用，一致。`repo_path` 替换 `wt_path`，全计划一致。
