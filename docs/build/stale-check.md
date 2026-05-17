# kyb 构建过期检测方案

## 背景

`kyb create` 已不再自动 build（详见 `async-build.md`），但用户可能忘记手动 build，导致使用过时的镜像。

需求：在 `kyb create` / `kyb enter` 时检测 `kyb-base:latest` 是否过期（Dockerfile / entrypoint / base image 有变更），过期则提示用户运行 `kyb build`。

## 设计原则

1. **只警告，不自动 build** — 不破坏 build/create 解耦
2. **Docker 原生检测** — 利用 BuildKit layer cache 判断镜像是否最新
3. **零阻塞** — 检测过程 < 2 秒（cache hit 时），过期时立即终止不等待构建
4. **静默容错** — 检测异常时静默忽略，不阻塞正常流程

## 检测机制

### 核心思想

运行 `docker build --progress=plain -t <temp_tag>`，利用 BuildKit 的输出判断：

- 每层 `CACHED` → 镜像最新
- 出现非 CACHED 的构建输出 → 镜像过期

### 实现：`Kyb::Docker.stale?`

```
def stale?(tag, path)
  1. 生成临时 tag: kyb-base:stale-check-<timestamp>
  2. spawn docker build -t temp_tag --progress=plain path
  3. 逐行读取 stdout
  4. 正则匹配 /#\d+ \d+\.\d+s / → 发现真正构建 → kill 进程 → return true
  5. 全部 CACHED → 等待进程结束 → return false
  ensure:
  6. docker rmi temp_tag（清理）
rescue => e
  7. warn "stale check failed: #{e.message}"（静默容错）
end
```

关键点：
- 临时 tag 避免 `latest` 被污染（kill 时不会损坏现有镜像）
- `ensure` 清理临时镜像避免残留
- 异常时只 warn 不阻塞 create/enter

## 用户交互

### kyb enter

```
kyb enter PROJECT-BRANCH
  → kyb-base:latest 存在？
    → 否：提示 "Build it first: kyb build"（已有逻辑），退出
    → 是：stale? 检查
      → 过期：
        1. 打印黄色警告 "⚠ kyb-base:latest is outdated (Dockerfile changed).
           Run 'kyb build' on host to update.
           Continue? [Y/n] (5s auto: Y) "
        2. 等待用户输入 / 5 秒超时
           - Enter / 超时 → continue_msg = "（基础镜像可能已过期，建议运行 kyb build 更新）"
           - n / N → 退出
        3. 将 continue_msg 附加到 Claude Code 的默认 prompt 末尾
      → 最新：静默，无输出
  → 进入容器（tmux send-keys）
```

### kyb create

```
kyb create PROJECT-BRANCH
  → ...（创建容器）
  → stale? 检查
    → 过期：打印警告 "⚠ kyb-base:latest is outdated. Run 'kyb build' to update."
           提示 "Continue? [Y/n] (5s auto: Y) "，Enter/超时继续，n 退出
    → 最新：静默
  → 输出 Container ready 信息
```

### 等待逻辑

```ruby
def wait_with_timeout(prompt, timeout: 5)
  print prompt
  STDOUT.flush
  input = IO.select([STDIN], nil, nil, timeout)
  if input
    STDIN.gets.to_s.strip.downcase
  else
    puts  # 超时，换行
    ''    # 等同于回车
  end
end
```

## Prompt 传递

修改 `lib/kyb/cli/enter.rb` 中的 `default_prompt`：

```ruby
default_prompt = '@CLAUDE.md @README.md @~/.claude/CLAUDE.md 先读一下项目文档和环境说明'
if stale_msg
  default_prompt += " #{stale_msg}"
end
```

stale_msg 内容：
> ⚠ 注意：当前容器使用的基础镜像（kyb-base:latest）可能已过时。Dockerfile 有更新但未重新构建。如需安装新的系统包或工具链，请在宿主机执行 `kyb build`。

这样 Claude Code 启动后 AI 第一时间就知道镜像可能过时，避免用户在容器内装了半天装不上才发现是镜像问题。

## 修改文件

| 文件 | 改动 |
|------|------|
| `lib/kyb/docker.rb` | 新增 `stale?`, `build_output_contains_build_line?`, `layers_differ?` |
| `lib/kyb/cli/create.rb` | create 后追加 stale check + 等待确认 |
| `lib/kyb/cli/enter.rb` | enter 前追加 stale check + 等待确认 + prompt 传递 |
| `test/test_docker.rb` | 单元测试：输出解析、layer 对比 |
| `test/test_stale.rb` | 集成测试：真实 Docker 构建验证 |
| `test/test_stale_cli.rb` | CLI 测试：警告、确认、prompt 注入 |

## 实现

### stale? 核心逻辑

```ruby
def stale?(tag, path)
  check_tag = "#{tag}:stale-check-#{Time.now.to_i}"
  rd, wr = IO.pipe
  pid = spawn({ 'DOCKER_BUILDKIT' => '1' },
    'docker', 'build', '--progress=plain', '-t', check_tag, path.to_s,
    out: wr, err: [:child, :out])
  wr.close

  stale = false
  buffer = +''
  loop do
    ready = IO.select([rd], nil, nil, 0.1)
    if ready
      begin
        buffer << rd.read_nonblock(4096)
        if build_output_contains_build_line?(buffer)
          stale = true; Process.kill('TERM', pid); break
        end
      rescue IO::EAGAINWaitReadable
      rescue EOFError
      end
    end
    _, status = Process.wait2(pid, Process::WNOHANG)
    next unless status
    stale = layers_differ?(tag, check_tag)
    break
  end
  rd.close; Process.wait(pid) rescue nil
  system('docker', 'rmi', '-f', check_tag, out: File::NULL, err: File::NULL)
  stale
rescue => e
  warn "stale check failed: #{e.message}"; false
end
```

两层检测：
1. 进程运行中 → 实时解析 BuildKit `--progress=plain` 输出，匹配 `#N M.Ns TEXT`（中间构建输出），发现即 kill
2. 进程退出后兜底 → 对比 `docker inspect --format='{{.RootFS.Layers}}'` layer digest，不一致则过期

### build_output_contains_build_line?

```ruby
def build_output_contains_build_line?(output)
  output.match?(/#\d+ \d+\.\d+s /)
end
```

匹配 BuildKit 中间输出行 `#5 0.315s Running apt-get...`，不匹配 `#5 CACHED` 和 `#5 DONE 12.5s`。

### layers_differ?

```ruby
def layers_differ?(tag1, tag2)
  layers1 = `docker inspect --format='{{.RootFS.Layers}}' #{tag1} 2>/dev/null`.strip
  layers2 = `docker inspect --format='{{.RootFS.Layers}}' #{tag2} 2>/dev/null`.strip
  return false if layers1.empty? || layers2.empty?
  layers1 != layers2
end
```

### kyb create 集成

create 完成后检查过期，警告 + 5 秒超时确认：

```ruby
if Kyb::Docker.image_exists?(Kyb::Container::BASE_IMAGE)
  path = Kyb::Config.base_image_path
  if Kyb::Docker.stale?(Kyb::Container::BASE_IMAGE, path)
    puts "==> ⚠ kyb-base:latest is outdated (Dockerfile changed)."
    puts "    Run 'kyb build' on host to update."
    print "    Continue? [Y/n] (5s auto: Y) "
    STDOUT.flush
    input = IO.select([STDIN], nil, nil, 5)
    if input
      ans = STDIN.gets.to_s.strip.downcase
      if ans == 'n' || ans == 'no'
        puts "    Aborted."; exit 0
      end
    else
      puts
    end
  end
end
```

### kyb enter 集成

进入前检查，过期时注入 Claude Code prompt：

```ruby
stale_msg = nil
if Kyb::Docker.image_exists?(Kyb::Container::BASE_IMAGE) &&
   Kyb::Docker.stale?(Kyb::Container::BASE_IMAGE, Kyb::Config.base_image_path)
  # ... 警告 + 确认 ...
  stale_msg = '（基础镜像可能已过时，建议运行 kyb build 更新）'
end

default_prompt = '@CLAUDE.md @README.md @~/.claude/CLAUDE.md 先读一下项目文档和环境说明'
default_prompt += " #{stale_msg}" if stale_msg
```
