# kyb create DinD Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `kyb create` in DinD mode — replace broken host-only bind mounts with tar pipe injection, add mise/pip cache volumes, restore conditional PG autostart.

**Architecture:** 5 self-contained steps: entrypoint PG fix → cache volumes → DinD mount skip in `run` → tar pipe inject in `create_container` → worktree tar pipe.

**Tech Stack:** Ruby (kyb CLI), Bash (entrypoint.sh), Docker, Minitest

---
### Task 1: Add conditional PG autostart to entrypoint

**Files:**
- Modify: `entrypoint.sh:196-199`
- Modify: `test/test_entrypoint.rb:34-37`

**Context:** PG autostart was removed globally during DID optimization. DID containers don't need it, but regular `kyb create` containers do. Add it after the sentinel so it doesn't block startup perception.

- [ ] **Step 1: Write failing test for PG autostart in non-DID mode**

Add to `test/test_entrypoint.rb` after line 37:

```ruby
def test_postgresql_runs_in_non_did
  start_container
  assert(exec_bool('pg_isready'),
         'PostgreSQL should be auto-started for non-DID containers')
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_entrypoint.rb -n test_postgresql_runs_in_non_did`
Expected: FAIL

- [ ] **Step 3: Add conditional PG start to entrypoint.sh**

After line 196 (`touch /tmp/kyb-ready`), before pip install:

```bash
touch /tmp/kyb-ready

# Start PostgreSQL in non-DID containers (DID doesn't need it)
if [ -z "${KYB_DID:-}" ]; then
    pg_ctlcluster 16 main start 2>/dev/null || true
fi
```

- [ ] **Step 4: Update existing test to match new behavior**

Change `test_postgresql_not_running` near line 34:

```ruby
def test_postgresql_not_running_in_did
  cname = "#{CONTAINER}-did"
  system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
  system('docker', 'run', '-d', '--name', cname,
         '-e', 'KYB_DID=1',
         '-e', 'HOST_UID=1000', '-e', 'HOST_GID=1000',
         IMAGE, 'sleep', '300',
         out: File::NULL, err: File::NULL)
  wait_for_ready(cname)

  refute(exec_bool_in(cname, 'pg_isready'),
         'PostgreSQL should not auto-start in DID containers')
  system('docker', 'rm', '-f', cname, out: File::NULL, err: File::NULL)
end
```

- [ ] **Step 5: Run all entrypoint tests**

Run: `ruby -Itest test/test_entrypoint.rb`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh test/test_entrypoint.rb
git commit -m "fix: conditionally start PostgreSQL in entrypoint

PG autostart was removed globally during DID optimization. Restore it
for non-DID containers (after sentinel, non-blocking). DID containers
skip via KYB_DID env var check.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---
### Task 2: Add mise/pip cache volumes to Kyb::Docker.run

**Files:**
- Modify: `lib/kyb/docker.rb:176-180`
- Test: `test/test_docker.rb`

**Context:** DID mounts `kyb-mise-cache` and `kyb-pip-cache` (did.rb:87-93) but `Kyb::Docker.run` only mounts `kyb-gradle-cache` and `kyb-maven-cache`. Add the missing two.

- [ ] **Step 1: Write failing test**

Near line 202 (`# --- run (Swift cache volume) ---`), add:

```ruby
# --- run (mise/pip cache volumes) ---

def test_run_mounts_mise_and_pip_cache_volumes
  wt_path = '/tmp/test-wt-cache'
  FileUtils.mkdir_p(wt_path)
  args = with_run_stubs(dind: false, **default_run_kwargs(wt_path: wt_path))
  assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-mise-cache:/home/dev/.local/share/mise/downloads' },
         'expected kyb-mise-cache volume mount'
  assert args.each_cons(2).any? { |f, v| f == '-v' && v == 'kyb-pip-cache:/home/dev/.cache/pip' },
         'expected kyb-pip-cache volume mount'
ensure
  FileUtils.rm_rf('/tmp/test-wt-cache')
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_docker.rb -n test_run_mounts_mise_and_pip_cache_volumes`
Expected: FAIL

- [ ] **Step 3: Add mise/pip cache volume creation and mounts**

In `lib/kyb/docker.rb` lines 176-180, change:

```ruby
    # Current:
    %w[kyb-gradle-cache kyb-maven-cache].each do |vol|

    # After:
    %w[kyb-gradle-cache kyb-maven-cache kyb-mise-cache kyb-pip-cache].each do |vol|
```

After line 180, add:

```ruby
    args += ['-v', 'kyb-mise-cache:/home/dev/.local/share/mise/downloads']
    args += ['-v', 'kyb-pip-cache:/home/dev/.cache/pip']
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_docker.rb -n test_run_mounts_mise_and_pip_cache_volumes`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `ruby -Itest test/`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/kyb/docker.rb test/test_docker.rb
git commit -m "feat: add kyb-mise-cache and kyb-pip-cache volumes to docker run

Matching DID's cache volume setup (did.rb). Mise downloads and pip
packages now persist across container recreation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---
### Task 3: Skip host-only bind mounts in DinD mode

**Files:**
- Modify: `lib/kyb/docker.rb:124-138,148-169`
- Test: `test/test_docker.rb`

**Context:** In DinD mode (`/.dockerenv`), host paths like `~/.ssh`, `~/.gitconfig`, `~/.claude/settings.json` don't exist on the macOS host. Docker daemon creates empty files for them, breaking entrypoint. Skip them in DinD mode.

- [ ] **Step 1: Write failing test**

After `test_run_dind_uses_named_volume` (line 200), add:

```ruby
def test_run_dind_skips_host_only_bind_mounts
  wt_path = '/tmp/test-wt-dind-skip'
  FileUtils.mkdir_p(wt_path)
  args = with_run_stubs(dind: true, **default_run_kwargs(wt_path: wt_path))

  # These host-only mounts should NOT appear in DinD mode
  bad_mounts = args.each_cons(2).select { |f, v| f == '-v' && (
    v.include?('/home/dev/.ssh') ||
    v.include?('/home/dev/.gitconfig') ||
    v.include?('/home/dev/.claude-host-settings') ||
    v.include?('/home/dev/.claude-skills-host') ||
    v.include?('/home/dev/.kimi') ||
    v.include?('/home/.agents') ||
    v.include?('/home/dev/.config/kyb') ||
    v.include?('kyb_repo')  # kyb_repo path
  ) }
  assert_empty bad_mounts, "expected no host-only bind mounts in DinD mode, got: #{bad_mounts.map { |_, v| v }}"
ensure
  FileUtils.rm_rf('/tmp/test-wt-dind-skip')
end

def test_run_dind_skips_project_path_and_symlinks
  wt_path = '/tmp/test-wt-dind-skip2'
  FileUtils.mkdir_p(wt_path)
  pp = '/tmp/test-project-pp2'
  args = with_run_stubs(dind: true, **default_run_kwargs(
    wt_path: wt_path, project_path: pp,
    symlinks: 'shared/vendor', mounts_rw: '/host/rw:/container/rw', mounts_ro: '/host/ro:/container/ro'))
  # These should NOT appear in DinD
  refute args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}:#{pp}" },
         'project_path bind mount should be skipped in DinD'
  refute args.each_cons(2).any? { |f, v| f == '-v' && v == "#{pp}/shared/vendor:/home/dev/projects/niao/shared/vendor:ro" },
         'symlinks should be skipped in DinD'
  refute args.each_cons(2).any? { |f, v| f == '-v' && v == '/host/rw:/container/rw' },
         'mounts_rw should be skipped in DinD'
  refute args.each_cons(2).any? { |f, v| f == '-v' && v == '/host/ro:/container/ro:ro' },
         'mounts_ro should be skipped in DinD'
ensure
  FileUtils.rm_rf('/tmp/test-wt-dind-skip2')
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
ruby -Itest test/test_docker.rb -n test_run_dind_skips_host_only_bind_mounts
ruby -Itest test/test_docker.rb -n test_run_dind_skips_project_path_and_symlinks
```
Expected: FAIL

- [ ] **Step 3: Modify `run` method to skip host-only mounts in DinD**

At `lib/kyb/docker.rb` line 124, add check before host-only mounts:

```ruby
    ssh_dir = File.expand_path('~/.ssh')
    # In DinD mode, host-only bind mounts don't exist on the Docker host (macOS),
    # so Docker creates empty files/dirs that break the container entrypoint.
    # Skip all host-path-dependent mounts and inject files via tar pipe instead.
    unless dind
      args += ['-v', "#{ssh_dir}:/home/dev/.ssh:ro"] if File.directory?(ssh_dir)
      kyb_dir = File.expand_path('~/.kyb')
      FileUtils.mkdir_p(kyb_dir) unless File.directory?(kyb_dir)
      args += ['-v', "#{kyb_dir}:#{kyb_dir}"]
      args += ['-v', "#{ENV['HOME']}/.kimi:/home/dev/.kimi"]
      args += ['-v', "#{ENV['HOME']}/.gitconfig:/home/dev/.gitconfig:ro"]
      args += ['-v', "#{ENV['HOME']}/.claude/settings.json:/home/dev/.claude-host-settings.json:ro"]
      kyb_config = File.expand_path('~/.config/kyb')
      args += ['-v', "#{kyb_config}:/home/dev/.config/kyb:ro"] if File.directory?(kyb_config)
      skills = File.expand_path('~/.claude/skills')
      args += ['-v', "#{skills}:/home/dev/.claude-skills-host:ro"] if File.directory?(skills)
      agents = File.expand_path('~/.agents')
      args += ['-v', "#{agents}:/home/.agents:ro"] if File.directory?(agents)
    end
```

Then wrap lines 148-169 (project_path, symlinks, mounts_rw, mounts_ro) in the same `unless dind`:

```ruby
    unless dind
      unless project_path == "/home/dev/projects/#{project_name}"
        args += ['-v', "#{project_path}:#{project_path}"]
      end

      symlinks.to_s.split(',').each do |link|
        next if link.empty?
        args += ['-v', "#{project_path}/#{link}:/home/dev/projects/#{project_name}/#{link}:ro"]
      end

      mounts_rw.to_s.split(',').each do |m|
        next if m.empty?
        host_path, container_path = m.split(':', 2)
        next unless host_path && container_path
        args += ['-v', "#{File.expand_path(host_path)}:#{container_path}"]
      end

      mounts_ro.to_s.split(',').each do |m|
        next if m.empty?
        host_path, container_path = m.split(':', 2)
        next unless host_path && container_path
        args += ['-v', "#{File.expand_path(host_path)}:#{container_path}:ro"]
      end
    end
```

Also wrap `kyb_repo` mount (line 189-190):

```ruby
    unless dind
      kyb_repo = Kyb::Config.kyb_repo
      args += ['-v', "#{kyb_repo}:/home/dev/kyb:ro"] if kyb_repo
    end
```

**Important:** The `dind` variable is already defined at line 138: `dind = File.exist?('/.dockerenv')`. No need to redefine.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
ruby -Itest test/test_docker.rb -n test_run_dind_skips_host_only_bind_mounts
ruby -Itest test/test_docker.rb -n test_run_dind_skips_project_path_and_symlinks
ruby -Itest test/test_docker.rb -n test_run_dind_uses_named_volume
ruby -Itest test/test_docker.rb -n test_run_normal_mode_binds_wt_path
```
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `ruby -Itest test/`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/kyb/docker.rb test/test_docker.rb
git commit -m "fix: skip host-only bind mounts in DinD mode for kyb create

Host paths like ~/.ssh, ~/.gitconfig don't exist on the Docker host
(macOS) when running inside a container. Skip them in DinD mode and
inject via tar pipe after container start. Also skips project_path,
symlinks, mounts_rw/ro, and kyb_repo mounts that reference host paths.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---
### Task 4: Add tar pipe injection to create_container

**Files:**
- Modify: `lib/kyb/docker.rb:290-293`
- Test: `test/test_docker.rb`

**Context:** After container starts (sentinel wait), inject .ssh, .gitconfig, .config/kyb via tar pipe (same pattern as DID `cli/did.rb:126-132`).

- [ ] **Step 1: Write failing test**

After `test_create_container_dind_copies_worktree` (line 302), add:

```ruby
def test_create_container_dind_tar_pipe_injects_host_files
  tar_cmd = nil
  sys_stub = ->(*args) {
    tar_cmd = args.first if args.first.is_a?(String) && args.first.include?('tar -C')
    true
  }

  with_dind(true) do
    Kyb::Docker.stub(:system, sys_stub) do
      stub_create_container_deps do
        Kyb::Docker.create_container('niao', 'water')
      end
    end
  end

  refute_nil tar_cmd, 'expected tar pipe command in DinD mode'
  assert tar_cmd.include?('.ssh'), 'tar pipe should include .ssh'
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_docker.rb -n test_create_container_dind_tar_pipe_injects_host_files`
Expected: FAIL

- [ ] **Step 3: Implement tar pipe injection**

After the sentinel wait loop (after line 288), before worktree copy:

```ruby
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

      puts "==> #{container.name}: copying worktree into container"
      system('docker', 'cp', "#{wt_path}/.", "#{container.name}:/home/dev/projects/#{project}/")
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_docker.rb -n test_create_container_dind_tar_pipe_injects_host_files`
Expected: PASS

- [ ] **Step 5: Run existing DinD tests**

Run: `ruby -Itest test/test_docker.rb -n test_create_container_dind_copies_worktree`
Expected: PASS (docker cp still called)

- [ ] **Step 6: Run full test suite**

Run: `ruby -Itest test/`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/kyb/docker.rb test/test_docker.rb
git commit -m "fix: inject host config files via tar pipe in DinD mode

Reuses the same pattern from did.rb — single tar pipe to inject .ssh,
.gitconfig, and .config/kyb after container start, avoiding broken
host-only bind mounts.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---
### Task 5: Replace DinD worktree docker cp with tar pipe

**Files:**
- Modify: `lib/kyb/docker.rb:291-293`
- Test: `test/test_docker.rb:289-301`

**Context:** Convert worktree copying from `docker cp` to tar pipe for consistency with DID approach.

- [ ] **Step 1: Update existing test**

Change `test_create_container_dind_copies_worktree` (line 289-302) to expect tar pipe instead of `docker cp`:

```ruby
def test_create_container_dind_copies_worktree_via_tar
  wt_paths = []
  sys_stub = ->(*args) {
    if args.first.is_a?(String) && args.first.include?('tar -C') && args.first.include?('worktrees')
      wt_paths << args.first[/tar -C ([^ ]+)/, 1]
    end
    true
  }

  with_dind(true) do
    Kyb::Docker.stub(:system, sys_stub) do
      stub_create_container_deps do
        Kyb::Docker.create_container('niao', 'water')
      end
    end
  end

  assert wt_paths.any?, 'expected tar pipe for worktree in DinD mode'
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_docker.rb -n test_create_container_dind_copies_worktree_via_tar`
Expected: FAIL

- [ ] **Step 3: Replace docker cp with tar pipe**

In `lib/kyb/docker.rb` around line 291-293, replace:

```ruby
      puts "==> #{container.name}: copying worktree into container"
      system('docker', 'cp', "#{wt_path}/.", "#{container.name}:/home/dev/projects/#{project}/")
```

With:

```ruby
      puts "==> #{container.name}: copying worktree into container"
      system('bash', '-c',
        "tar -C #{File.dirname(wt_path)} -c #{File.basename(wt_path)} 2>/dev/null | " \
        "docker exec -i #{container.name} bash -c '" \
        "tar -C /home/dev/projects -x " \
        "&& chown -R dev:dev /home/dev/projects/#{project} 2>/dev/null || true'")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_docker.rb -n test_create_container_dind_copies_worktree_via_tar`
Expected: PASS

- [ ] **Step 5: Run all DinD-related tests**

Run:
```bash
ruby -Itest test/test_docker.rb -n /dind/i
```
Expected: All pass

- [ ] **Step 6: Run full test suite**

Run: `ruby -Itest test/`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/kyb/docker.rb test/test_docker.rb
git commit -m "refactor: replace DinD worktree docker cp with tar pipe

Consistent with DID approach. Single tar pipe avoids docker cp's
serial file traversal through Docker API.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---
### Task 6: Push and create MR

**Files:** N/A (git operations)

- [ ] **Step 1: Push to remote**

```bash
git push origin kyb/kyb-did
```

- [ ] **Step 2: Create MR via glab**

```bash
glab mr create --fill --yes
```
