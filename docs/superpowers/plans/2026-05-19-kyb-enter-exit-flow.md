# kyb Enter Exit Flow Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign `kyb enter` so that when the user exits a container, the system runs idle checks and optionally cleans up — without deleting containers where work is still in progress.

**Architecture:** 4 components: (1) new `kyb session wrap` subcommand for tracking CLI sessions inside containers, (2) `kyb enter` exit-flow rewrite (`exec` → `system`), (3) idle check pipeline (tmux alive?, worktree clean?, remote synced?), (4) interactive delete prompt with 5s timeout. Checks run on the host (outside container) so they see real git state.

**Tech Stack:** Ruby (kyb CLI), Minitest, Docker CLI (docker exec, docker ps, docker inspect), Git

---

### Task 1: Add `session` subcommand to CLI dispatch

**Files:**
- Modify: `lib/kyb/cli.rb:95-99` (dispatch), `lib/kyb/cli.rb:127-134` (help)
- Create: `lib/kyb/cli/session.rb`
- Test: `test/test_session.rb`

- [ ] **Step 1: Register `session` subcommand in cli.rb dispatch**

Add to `lib/kyb/cli.rb` after the `tts` when-block (around line 85), before `notify`:

```ruby
    when 'session'
      Kyb.die("Usage: kyb session wrap <cli> [args...]") unless args.first == 'wrap' && args.size >= 2
      session_wrap(args[1], args[2..])
```

Add `require_relative 'cli/session'` to the bottom of `lib/kyb/cli.rb` (after tts, around line 145):

```ruby
require_relative 'cli/session'
```

Add to help text (after `notify` line, before `version`):

```
        session wrap <cli> [args...]     Wrap CLI command with session tracking
```

- [ ] **Step 2: Write unit test for session dispatch**

Add to `test/test_session.rb`:

```ruby
require_relative 'test_helper'

class SessionTest < Minitest::Test
  def setup
    Kyb::Config.define_singleton_method(:load) { nil }

    Kyb::CLI.define_singleton_method(:session_wrap) do |cli, prompt|
      @__captured = [:session_wrap, cli, prompt]
    end
  end

  def teardown
    Kyb::Config.singleton_class.remove_method(:load)
    Kyb::CLI.singleton_class.remove_method(:session_wrap)
  end

  def dispatch(*argv)
    Kyb::CLI.instance_variable_set(:@__captured, nil)
    Kyb::CLI.dispatch(argv)
    Kyb::CLI.instance_variable_get(:@__captured)
  end

  def test_session_wrap_dispatch
    cmd, cli, prompt = dispatch('session', 'wrap', 'claude', 'read doc')
    assert_equal :session_wrap, cmd
    assert_equal 'claude', cli
    assert_equal ['read doc'], prompt
  end

  def test_session_wrap_no_args_dies
    assert_raises(SystemExit) { dispatch('session') }
  end

  def test_session_wrap_no_command_dies
    assert_raises(SystemExit) { dispatch('session', 'wrap') }
  end
end
```

- [ ] **Step 3: Run test to verify failures**

Run: `ruby -Itest test/test_session.rb -n test_session_wrap_dispatch`
Expected: PASS for dispatch test (but `session_wrap` method doesn't exist yet)

- [ ] **Step 4: Implement `session_wrap` method**

Create `lib/kyb/cli/session.rb`:

```ruby
# frozen_string_literal: true

module Kyb::CLI
  module_function

  def session_wrap(cli, prompt = nil)
    start_time = Time.now
    args = [cli, prompt].compact

    # exec the CLI — no return until it exits
    exec(*args)
  rescue Errno::ENOENT
    Kyb.die("CLI not found: #{cli}")
  end
end
```

This is the initial shell — the full session tracking (duration, stats) will be implemented in Task 2.

- [ ] **Step 5: Run tests to verify pass**

Run: `ruby -Itest test/test_session.rb`
Expected: 2 PASS, 1 FAIL (the wrap dispatch test should now pass, no-args tests pass)

Wait — the `exec` in session_wrap will replace the test process. The tests that call dispatch with session wrap args will exec and never return. I need to handle this differently.

**Fix the approach**: The `session_wrap` method should NOT exec in the test flow. Instead, stub it. For the unit test, we just test dispatch routing, not the actual behavior. The actual behavior test will need integration-level testing.

The test is correct as-is because we stub `session_wrap` via `define_singleton_method`. Test will pass.

- [ ] **Step 6: Commit**

```bash
git add lib/kyb/cli.rb lib/kyb/cli/session.rb test/test_session.rb
git commit -m "feat: add session subcommand skeleton"
```

---

### Task 2: Implement `kyb session wrap` with tracking

**Files:**
- Modify: `lib/kyb/cli/session.rb`
- Test: `test/test_session.rb`

- [ ] **Step 1: Write the test for session tracking**

Add to `test/test_session.rb`:

```ruby
  def test_session_wrap_records_duration
    start = Time.now
    # Simulate a quick session by wrapping `echo` instead of `claude`
    out, err = capture_subprocess_io do
      # Can't easily test exec() — test the stats formatting only
    end
  end

  def test_session_stats_format
    stats = Kyb::CLI.session_stats(3665, 'claude')  # 1h 1m 5s
    assert_includes stats, '1h 1m 5s'
    assert_includes stats, 'claude'
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_session.rb -n test_session_stats_format`
Expected: FAIL — `session_stats` not defined

- [ ] **Step 3: Implement session tracking**

The `kyb session wrap` command is designed to run INSIDE the container (in tmux). It wraps the CLI command, records timing, and prints a summary on exit.

Replace `lib/kyb/cli/session.rb`:

```ruby
# frozen_string_literal: true

module Kyb::CLI
  module_function

  def session_wrap(cli, prompt = nil)
    start_time = Time.now

    pid = spawn(cli, *[prompt].compact)
    Process.wait(pid)

    duration = Time.now - start_time
    puts
    puts format_session_stats(duration, cli)

    unless inside_tmux?
      return
    end

    puts "Still inside tmux session. Type 'exit' to close this container."
  rescue Errno::ENOENT
    Kyb.die("CLI not found: #{cli}")
  end

  def format_session_stats(duration_secs, cli)
    dur = format_duration(duration_secs)
    <<~STATS.strip
      \n━━━ Session ━━━━━━━
      Duration:  #{dur}
      Command:   #{cli}
      ────────────────────
    STATS
  end

  def format_duration(secs)
    secs = secs.to_i
    h = secs / 3600
    m = (secs % 3600) / 60
    s = secs % 60
    if h > 0
      format('%dh %dm %ds', h, m, s)
    elsif m > 0
      format('%dm %ds', m, s)
    else
      format('%ds', s)
    end
  end

  def inside_tmux?
    ENV.key?('TMUX')
  end
end
```

Wait — `exec` was better than `spawn` + `wait` for signal handling. But `spawn` + `wait` is needed because we need to do work AFTER the wrapped process exits. With `exec`, the process is replaced. Let me think...

Actually `spawn` + `wait` is the right choice here — we need to run code after the CLI finishes. `Process.wait(pid)` blocks until the child exits, then we print stats. Signal handling still works because signals go to the process group.

But wait, inside tmux, `Process.wait` might not work great with signals. Actually in a Ruby script, it works fine. `Process.wait` returns when the child exits. Ctrl-C goes to the foreground process group which is the Ruby script. The child gets killed too since it's in the same process group... hmm.

Actually let me look at how claude is run currently:
```ruby
send-keys "cd ~/projects/kyb && mise trust && claude 'prompt'" Enter
```
This sends the command as keyboard input to the tmux shell. The `kyb session wrap` would be the command itself, not a wrapper running in the background.

So inside tmux, `kyb session wrap claude 'prompt'` runs as the shell command. `spawn` creates a child process (claude), `Process.wait` waits for it. When claude exits, we print stats. This is clean.

But wait, `spawn` with a string like `"claude 'prompt'"` uses shell expansion, which is what we want. Actually, `spawn(*args)` with an array bypasses shell. We need:

Actually looking again, `spawn(cli, *[prompt].compact)` - this runs claude directly with prompt as an argument. But the current send-keys runs: `cd ~/projects/kyb && mise trust && claude 'prompt'`. So the `cd` and `mise trust` are run BEFORE `kyb session wrap` in the send-keys command.

The send-keys will become:
```
cd ~/projects/kyb && mise trust && /home/dev/kyb/bin/kyb session wrap claude 'prompt'
```

Inside session_wrap, `spawn('claude', 'prompt')` should find claude in PATH (since mise trust was already run).

Actually no - `spawn` with separate args doesn't use a shell. It finds `claude` in PATH using `execvp` semantics. This should work since mise trust adds mise shims to PATH.

Hmm, but `mise trust` in the send-keys only marks the config as trusted. It doesn't add to PATH. `mise` uses shims that are already in PATH. So `claude` should be findable via mise shims regardless of `mise trust`.

OK this will work. Let me continue with the plan.

Actually wait, I need to reconsider the `spawn` approach. When running inside tmux:
- The shell runs: `kyb session wrap claude 'prompt'`
- Ruby does `spawn('claude', 'prompt')`
- This creates claude as a child process of the Ruby process
- When you Ctrl-C inside tmux, it sends SIGINT to the foreground process (Ruby)
- Ruby might or might not forward it to claude

Actually with `spawn`, signals from the terminal go to the foreground process group leader. If Ruby is the leader, it gets the signal, but claude doesn't unless we explicitly forward it.

Better approach: use `exec` but wrap it in a forked process:
```ruby
pid = fork do
  exec(cli, *[prompt].compact)
end
Process.wait(pid)
```

With `fork`, the child process becomes the foreground process and gets signals directly. When the child exits, `Process.wait` returns.

Actually, even simpler — just use `system`:
```ruby
system(cli, *[prompt].compact)
```

`system` blocks until the command finishes and handles signals properly (the child is the foreground process). After system returns, we print stats.

But `system` returns the exit code, not the PID. We don't need the PID anyway.

Let me use `system`:

```ruby
def session_wrap(cli, prompt = nil)
  start_time = Time.now
  system(cli, *[prompt].compact)
  duration = Time.now - start_time
  puts format_session_stats(duration, cli)
  if inside_tmux?
    puts "Still inside tmux session. Type 'exit' to close this container."
  end
end
```

This is simpler and correct. `system` handles signal forwarding properly.

Let me also think about what happens when `claude` returns a non-zero exit code. `system` returns false. We should still print stats. The exit code of `kyb session wrap` itself should reflect the wrapped command's exit.

```ruby
def session_wrap(cli, prompt = nil)
  start_time = Time.now
  success = system(cli, *[prompt].compact)
  duration = Time.now - start_time
  puts format_session_stats(duration, cli)
  if inside_tmux?
    puts "Still inside tmux session. Type 'exit' to close this container."
  end
  exit(1) unless success
end
```

Wait no — `exit` inside session_wrap would exit the tmux shell, which is not what we want. The stat print is already telling them to type exit. Let's just let it return normally. The exit code matters less here since the user sees the output.

OK, let me finalize the implementation and write the plan properly.

- [ ] **Step 3: Implement session tracking**

Replace `lib/kyb/cli/session.rb`:

```ruby
# frozen_string_literal: true

module Kyb::CLI
  module_function

  def session_wrap(cli, cli_args = [])
    start_time = Time.now
    args = [cli, *cli_args].compact
    system(*args)
    duration = Time.now - start_time

    puts format_session_stats(duration, cli)
    if ENV.key?('TMUX')
      puts "Still inside tmux session. Type 'exit' to close this container."
    end
  end

  def format_session_stats(duration_secs, cli)
    dur = format_duration(duration_secs)
    <<~STATS.strip
      \n━━━ Session ━━━━━━━
      Duration:  #{dur}
      Command:   #{cli}
      ────────────────────
    STATS
  end

  def format_duration(secs)
    secs = secs.to_i
    h = secs / 3600
    m = (secs % 3600) / 60
    s = secs % 60
    if h > 0
      format('%dh %dm %ds', h, m, s)
    elsif m > 0
      format('%dm %ds', m, s)
    else
      format('%ds', s)
    end
  end
end
```

- [ ] **Step 4: Write tests for formatting**

Add to `test/test_session.rb`:

```ruby
class SessionTest < Minitest::Test
  def test_format_duration_seconds
    assert_equal '5s', Kyb::CLI.format_duration(5)
  end

  def test_format_duration_minutes
    assert_equal '2m 3s', Kyb::CLI.format_duration(123)
  end

  def test_format_duration_hours
    assert_equal '1h 0m 5s', Kyb::CLI.format_duration(3605)
  end

  def test_format_duration_zero
    assert_equal '0s', Kyb::CLI.format_duration(0)
  end

  def test_session_stats_format
    stats = Kyb::CLI.format_session_stats(3665, 'claude')
    assert_includes stats, '1h 1m 5s'
    assert_includes stats, 'claude'
  end
end
```

- [ ] **Step 5: Run tests**

Run: `ruby -Itest test/test_session.rb`
Expected: All PASS (duration format, stats format, and the earlier dispatch tests)

- [ ] **Step 6: Commit**

```bash
git add lib/kyb/cli/session.rb test/test_session.rb
git commit -m "feat: implement kyb session wrap with duration tracking"
```

---

### Task 3: Rewrite `kyb enter` exit flow — exec → system

**Files:**
- Modify: `lib/kyb/cli/enter.rb`
- Test: `test/test_cli.rb` (dispatch tests)

The core change: replace `exec(...)` with `system(...)`, then after return check if tmux session still exists inside the container.

- [ ] **Step 1: Understand current enter.rb flow**

Current enter.rb (read it fresh):

Lines 83-99:
```ruby
if system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev', ...)
  exec(*dexec, cname, 'tmux', ..., 'rename-window', title, ';', 'attach-session', '-t', 'dev')
else
  exec(*dexec, cname, 'tmux', ..., 'new-session', ..., 'send-keys', cmd, 'Enter')
end
```

Both branches use `exec` — they never return.

- [ ] **Step 2: Write test for detach vs exit detection**

Add to `test/test_session.rb`:

```ruby
  def test_tmux_session_exists_detects_alive
    # Stub docker exec: return success → tmux session alive
    Kyb::CLI.stub(:system, ->(*args, **kw) { args.include?('has-session') }) do
      # ...
    end
  end
```

Actually testing enter.rb is integration-level (requires actual Docker). Skip unit tests for this specific behavior and rely on dispatch tests + manual testing.

- [ ] **Step 3: Rewrite enter.rb — replace exec with system**

Replace the two `exec` calls with `system`, add post-return flow:

```ruby
def enter(project, branch, cli: 'claude')
  Kyb::Config.load
  container = Kyb::Container.new(project, branch)
  cname = container.name

  # ... (container create/start logic stays the same) ...
  # ... (stale image check stays the same) ...

  # Build the session-wrapped command for inside the container
  if cli == 'bash'
    cmd = "cd ~/projects/#{project}"
  else
    kyb_path = determine_kyb_path(project)
    cmd = "cd ~/projects/#{project} && mise trust && #{kyb_path} session wrap #{cli} '#{default_prompt}'"
  end

  dexec = [DOCKER, 'exec', '-it', '-u', 'dev', '-w', '/home/dev']
  dexec += ['-e', "KIMI_API_KEY=#{ENV['KIMI_API_KEY']}"] if ENV['KIMI_API_KEY']

  title = "kyb:#{cname}"

  if system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
            %i[out err] => File::NULL)
    system(*dexec, cname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'rename-window', title, ';',
           'attach-session', '-t', 'dev')
  else
    system(*dexec, cname, 'tmux',
           'set', '-g', 'set-titles', 'on', ';',
           'set', '-g', 'automatic-rename', 'off', ';',
           'set', '-g', 'set-titles-string', '#{pane_title}', ';',
           'new-session', '-s', 'dev', '-n', title, ';',
           'select-pane', '-T', title, ';',
           'send-keys', cmd, 'Enter')
  end

  # --- Above: same as before but system() instead of exec() ---
  # --- Below: new exit flow ---

  # After docker exec returns:
  if system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
            %i[out err] => File::NULL)
    # Detached — tmux still alive
    puts
    puts "==> ／人◕ ‿‿ ◕人＼ Container #{cname} still alive."
    puts "    Re-attach: kyb enter #{project}-#{branch}"
  else
    # Session exited — run idle checks
    enter_exit_cleanup(container, project, branch)
  end
end

def determine_kyb_path(project)
  # Inside a container: kyb repo is mounted at /home/dev/kyb
  # On the host: use PATH (find via `which kyb`)
  if File.exist?('/.dockerenv')
    '/home/dev/kyb/bin/kyb'
  else
    'kyb'
  end
end
```

Wait, `/.dockerenv` check — when `kyb enter` runs on the host, it's NOT inside a Docker container. The container is created by Docker. On the host, `kyb` is in PATH (installed). Inside the container... wait.

Actually `kyb enter` runs on the **host** (macOS or the kyb parent container). The send-keys command is typed INTO the container's tmux. So the path that matters is the PATH INSIDE the container.

Inside the container, `kyb` might not be in PATH. The kyb repo is mounted at `/home/dev/kyb` (if configured). But not all containers have this.

Hmm. The send-keys approach should work regardless. Let me think...

Inside every kyb container:
- The project worktree is at `/home/dev/projects/<project>`
- The kyb repo (if configured in `kyb_repo`) is at `/home/dev/kyb`

If `kyb_repo` is configured, `/home/dev/kyb/bin/kyb` exists. This is the most reliable path.

If `kyb_repo` is NOT configured, the only way is `~/projects/kyb/bin/kyb` (if the project IS kyb). But that's fragile.

For the general case:
1. If `/home/dev/kyb/bin/kyb` exists → use it
2. If `kyb` is in PATH → use it
3. Fallback: try both

Actually, the `kyb_repo` config is a base-level setting. Let me check if it's commonly configured. Looking at the config loading:

```ruby
def kyb_repo
  path = load_config.dig('base', 'kyb_repo')
  File.expand_path(path) if path
end
```

It's optional. But without it, `/home/dev/kyb` won't be mounted.

For the send-keys command, we can use a simple detection:
```ruby
cmd = "cd ~/projects/#{project} && mise trust && (command -v kyb && kyb || /home/dev/kyb/bin/kyb) session wrap #{cli} '#{default_prompt}'"
```

This is POSIX shell: `command -v kyb` checks if `kyb` is in PATH. If yes, use `kyb`. If not, try `/home/dev/kyb/bin/kyb`.

Actually this is getting complex. Let me just check: does entrypoint.sh add `/home/dev/kyb/bin` to PATH? Looking at:
- The entrypoint doesn't seem to (we checked earlier)
- But maybe we should add it as part of this change?

Or simpler: the send-keys can use `~/projects/kyb/bin/kyb` since if the user is entering a container, they have some worktree. If their worktree is `kyb`, this works. If not...

OK, the cleanest solution is:

```ruby
kyb_cmd = "kyb"
if File.exist?('/home/dev/kyb/bin/kyb')
  kyb_cmd = '/home/dev/kyb/bin/kyb'
elsif File.exist?(File.expand_path('~/projects/kyb/bin/kyb'))
  kyb_cmd = '~/projects/kyb/bin/kyb'
end
```

This runs on the HOST and checks what paths look valid INSIDE the container. `/home/dev/kyb` is the mount point of `kyb_repo`. `~/projects/kyb/bin/kyb` is the kyb project worktree.

Wait, this still runs on the host. `File.exist?('/home/dev/kyb/bin/kyb')` checks the HOST path, but `/home/dev/kyb` only exists inside the container!

Right. The send-keys command is typed INTO the container. So we need the path AS SEEN FROM INSIDE the container. From the host, we can check if `kyb_repo` is configured:

```ruby
kyb_path = Kyb::Config.kyb_repo ? '/home/dev/kyb/bin/kyb' : 'kyb'
```

If the user configured `kyb_repo` in their base config, `/home/dev/kyb/bin/kyb` will exist inside the container. Otherwise, we fall back to PATH (hoping `kyb` is installed inside the container).

This is clean and simple. Let me use this approach.

- [ ] **Step 4: Add `enter_exit_cleanup` stub**

Add to `lib/kyb/cli/enter.rb`:

```ruby
def enter_exit_cleanup(container, project, branch)
  cname = container.name
  puts
  puts "==> Container #{cname}: session ended."

  checks = run_idle_checks(container, project)
  all_pass = checks[:pass]

  if all_pass
    interactive_delete_prompt(container, project, branch)
  else
    puts "    Cleanup skipped (see warnings above)."
    puts "    Force delete: kyb rm #{project}-#{branch}"
  end
end

def run_idle_checks(container, project)
  cname = container.name
  results = {}

  # 1. tmux alive?
  tmux_alive = system('docker', 'exec', '-u', 'dev', cname, 'tmux', 'has-session', '-t', 'dev',
                      %i[out err] => File::NULL)
  results[:tmux] = !tmux_alive

  # 2. worktree clean?
  wt_path = container.worktree_path
  if wt_path && File.directory?(wt_path)
    dirty = !system('git', '--git-dir', "#{wt_path}/.git", '--work-tree', wt_path,
                    'diff', '--quiet', '--ignore-submodules')
    untracked = !system('git', '--git-dir', "#{wt_path}/.git", '--work-tree', wt_path,
                        'ls-files', '--others', '--exclude-standard', '--error-unmatch', '.',
                        %i[out err] => File::NULL)
    results[:worktree] = !dirty && untracked
  else
    results[:worktree] = false
  end

  # Print results header
  puts
  puts "━━━  Idle Check  ━━━"
  puts results[:tmux]     ? "  ✔ tmux:     no active sessions" : "  ✗ tmux:     session still alive"
  puts results[:worktree] ? "  ✔ worktree: clean"               : "  ✗ worktree: uncommitted changes"

  results[:pass] = results[:tmux] && results[:worktree]
  results
end

def interactive_delete_prompt(container, project, branch)
  cname = container.name
  puts
  puts "━━━  Container Idle  ━━━━━━━━━━━━━"
  puts "Container:  #{cname}"
  puts "Project:    #{project} / #{branch}"
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts "Cleanup will:"
  puts "  • stop & remove container"
  puts "  • delete worktree & git branch #{container.git_branch}"
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
    # Ctrl-C → treat as skip
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

  # Cascade remove DID children
  `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname}`.lines.map(&:strip).each do |did_child|
    puts "==> #{did_child}: removing DID child container"
    system('docker', 'rm', '-f', did_child)
    system('docker', 'volume', 'rm', "#{did_child}-worktree", out: File::NULL)
  end

  puts "==> #{cname}: stopping"
  system('docker', 'stop', cname)
  puts "==> #{cname}: removing"
  system('docker', 'rm', cname)

  # Worktree + git branch
  proj_config = Kyb::Config.project(project) rescue nil
  if proj_config && proj_config[:path]
    path = proj_config[:path]
    wt_path = container.worktree_path
    if wt_path && File.directory?(wt_path)
      Kyb::Git.remove_worktree(path, wt_path)
    end
    Kyb::Git.delete_local_branch(path, container)
  end

  # Claude volume
  Kyb::Docker.volume_rm(container.claude_volume)

  puts "==> Done. Container cleaned."
  puts
  puts "    Start fresh: kyb create #{project}-#{branch}"
end
```

- [ ] **Step 5: Handle remote check**

Add to `run_idle_checks`:

```ruby
  # 3. remote — check for unpushed commits
  if wt_path && File.directory?(wt_path)
    Dir.chdir(wt_path) do
      unpushed = `git cherry 2>/dev/null`.lines.count > 0
      results[:remote] = !unpushed
      puts unpushed ? "  ✗ remote:   unpushed commits" : "  ✔ remote:   all pushed"
    end
  else
    results[:remote] = false
    puts "  ✗ remote:   worktree not accessible"
  end

  results[:pass] = results[:tmux] && results[:worktree] && results[:remote]
```

- [ ] **Step 6: Handle additional warnings (processes, DID children)**

Before the interactive prompt, scan for extra info:

```ruby
def collect_extra_warnings(container)
  cname = container.name
  warnings = []

  # Unexpected processes
  baseline = %w[ps tmux bash zsh sh sleep postgres pg_ctl sshd entrypoint runuser claude kyb ruby python3 node tail]
  processes = `docker exec #{cname} ps -eo comm= 2>/dev/null`.lines.map(&:strip).reject(&:empty?).uniq
  unexpected = processes - baseline
  warnings << "processes: #{unexpected.join(', ')}" if unexpected.any?

  # DID children
  did_kids = `docker ps -a --format '{{.Names}}' --filter label=did_parent=#{cname} 2>/dev/null`.lines.map(&:strip).reject(&:empty?)
  warnings << "DID children: #{did_kids.join(', ')} (will be cascade deleted)" if did_kids.any?

  warnings
end
```

In `enter_exit_cleanup`, after checks pass and before prompt:

```ruby
  if all_pass
    warnings = collect_extra_warnings(container)
    warnings.each { |w| puts "  ⚠  #{w}" } if warnings.any?
    puts
    interactive_delete_prompt(container, project, branch)
  else
    ...
  end
```

- [ ] **Step 7: Run existing tests to ensure no regressions**

Run: `ruby -Itest test/test_cli.rb`
Expected: All PASS (enter dispatch still routes correctly)

Run: `ruby -Itest test/test_session.rb`
Expected: All PASS

- [ ] **Step 8: Commit**

```bash
git add lib/kyb/cli/enter.rb test/test_cli.rb
git commit -m "refactor: kyb enter exit flow — exec→system, add idle checks + cleanup"
```

---

### Task 4: Wire `kyb session wrap` into send-keys in enter.rb

**Files:**
- Modify: `lib/kyb/cli/enter.rb`

- [ ] **Step 1: Build the session-wrapped send-keys command**

In `lib/kyb/cli/enter.rb`, the `cmd` variable currently is:

```ruby
cmd = "cd ~/projects/#{project} && mise trust && #{cli}"
cmd += " '#{default_prompt}'" if cli == 'claude'
cmd += " -p '#{default_prompt}'" if cli == 'kimi'
```

Replace with:

```ruby
if cli == 'bash'
  cmd = "cd ~/projects/#{project}"
else
  kyb_in_container = Kyb::Config.kyb_repo ? '/home/dev/kyb/bin/kyb' : 'kyb'
  inner_cmd = "cd ~/projects/#{project} && mise trust && #{kyb_in_container} session wrap #{cli}"
  if cli == 'claude'
    inner_cmd += " '#{default_prompt}'"
  elsif cli == 'kimi'
    inner_cmd += " -p '#{default_prompt}'"
  end
  cmd = inner_cmd
end
```

Note: when the shell parses `kyb session wrap kimi -p 'my prompt'`, the args arrive as:
- `session` → subcommand
- `wrap` → mode
- `kimi` → cli
- `-p`, `my prompt` → cli_args (array passed to session_wrap)

Inside session_wrap: `system('kimi', '-p', 'my prompt')` — same as running `kimi -p 'my prompt'`.

- [ ] **Step 2: Run integration test**

```bash
kyb enter kyb-dod
# → should join tmux, claude starts via kyb session wrap
# → Ctrl-C / exit claude → should see session stats
# → exit tmux → should see idle checks
```

- [ ] **Step 3: Commit**

```bash
git add lib/kyb/cli/enter.rb
git commit -m "feat: wire kyb session wrap into kyb enter send-keys"
```

---

### Task 5: Volume size stat and UI polish

**Files:**
- Modify: `lib/kyb/cli/enter.rb` (interactive_delete_prompt)

- [ ] **Step 1: Add volume size to delete prompt**

```ruby
def volume_size(volume_name)
  output = `docker system df -v --format '{{.Size}}' 2>/dev/null`
  # Alternative: inspect volume
  size = `docker run --rm -v #{volume_name}:/vol alpine du -sh /vol 2>/dev/null`.strip.split.first
  size || '??'
end
```

This is expensive (spins up alpine). Simpler approach:

```ruby
def volume_size(volume_name)
  mountpoint = `docker volume inspect --format '{{.Mountpoint}}' #{volume_name} 2>/dev/null`.strip
  return '??' if mountpoint.empty?
  # On macOS, Docker volumes are on the Linux VM — need to check via container
  size = `docker run --rm -v #{volume_name}:/vol alpine sh -c 'du -sh /vol 2>/dev/null | cut -f1' 2>/dev/null`.strip
  size.empty? ? '??' : size
rescue
  '??'
end
```

Instead of running a container each time, just show the volume name without size. Simpler. Skip this for v1.

- [ ] **Step 2: Polish output formatting**

Make sure all output strings use consistent formatting:
- Section headers: `━━━  Title  ━━━`
- Steps: `==>` prefix
- Checkmarks: `✔` / `✗`
- Warnings: `⚠`

- [ ] **Step 3: Commit**

```bash
git add lib/kyb/cli/enter.rb
git commit -m "refactor: polish cleanup output formatting"
```

---

### Task 6: DinD edge case — skip worktree/remote checks

**Files:**
- Modify: `lib/kyb/cli/enter.rb` (run_idle_checks)

- [ ] **Step 1: Add DinD detection to idle checks**

In `run_idle_checks`, at the top:

```ruby
dind = File.exist?('/.dockerenv')
```

When `kyb` itself runs inside Docker (DinD mode), worktree and remote checks need to run INSIDE the target container:

```ruby
if dind
  # In DinD mode, run checks inside the container via docker exec
  results[:tmux] = ... # tmux check already works via docker exec from parent
  results[:worktree] = system('docker', 'exec', '-u', 'dev', cname, 'git', 'diff', '--quiet', '--ignore-submodules',
                               %i[out err] => File::NULL)
  results[:remote] = ...
end
```

For now, in DinD mode, always pass worktree/remote checks (they run inside the container which has the real worktree state):

```ruby
if dind
  results[:tmux] = !tmux_alive
  results[:worktree] = true  # Assume clean — worktree is inside container
  results[:remote] = true     # Assume synced — can't reliably check from parent
else
  # Normal mode — host-side checks
  ...
end
```

Actually no. When in DinD mode, we can still run the checks via `docker exec`:

```ruby
if dind
  results[:tmux] = !tmux_alive
  results[:worktree] = system('docker', 'exec', '-u', 'dev', cname,
                               'git', '-C', "/home/dev/projects/#{project}", 'diff', '--quiet',
                               %i[out err] => File::NULL)
  results[:remote] = system('docker', 'exec', '-u', 'dev', cname,
                             'bash', '-c', 'cd /home/dev/projects/' + project + ' && test "$(git cherry)" = ""',
                             %i[out err] => File::NULL)
end
```

This works because in DinD mode, the worktree IS inside the container at `/home/dev/projects/<project>`.

- [ ] **Step 2: Commit**

```bash
git add lib/kyb/cli/enter.rb
git commit -m "fix: handle DinD mode in idle checks"
```

---

### Task 7: Final integration test and self-review

**No files changed.**

- [ ] **Step 1: Run all tests**

```bash
ruby -Itest test/ 2>&1
```

Expected: No failures introduced.

- [ ] **Step 2: Manual integration test — claude path**

```bash
# Build with changes
# Create a test container
kyb create kyb-test-exit

# Enter it — should use kyb session wrap
kyb enter kyb-test-exit

# Inside: claude starts via session wrap
# Exit claude → see stats
# Exit tmux → see idle checks
# Detach (Prefix+d) → see "still alive" message
```

- [ ] **Step 3: Manual integration test — bash path**

```bash
kyb enter kyb-test-exit --cli bash
# Should drop to bash directly without session wrap
```

- [ ] **Step 4: Manual integration test — detach vs exit**

```bash
kyb enter kyb-test-exit
# Prefix+d to detach → message: "Container still alive. Re-attach: kyb enter kyb-test-exit"
kyb enter kyb-test-exit
# exit tmux → Idle check → prompt → cleanup (or skip)
```

- [ ] **Step 5: Clean up test container**

```bash
kyb rm kyb-test-exit  # or the exit-flow handles it
```

- [ ] **Step 6: Commit any remaining fixes**

```bash
git add -A
git commit -m "fix: polish based on integration testing"
```
