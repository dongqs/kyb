# 全面健壮性审计报告 — 2026-05-23

> 扫描范围：`lib/kyb/*.rb`, `test/*.rb`, `entrypoint.sh`, `Dockerfile`, `.gitlab-ci.yml`
> 总计：**25 HIGH / 40 MEDIUM / 30 LOW**

---

## 五大高杠杆目标

### 1. Shell 注入面 — 6 处
| 位置 | 代码 | 风险 |
|------|------|------|
| `check.rb` | `` `#{cmd}` `` — `capture_cmd` | 用户输入可注入 |
| `docker.rb` | `` `docker ps -a --filter name=kyb-#{name}` `` | project 名含特殊字符 |
| `docker.rb` | `tar -C #{home} \| docker exec -i #{cname} bash -c` | 容器名注入 |
| `exit_flow.rb` | `` `docker exec #{cname} ps -eo comm=` `` | 容器名注入 |
| `docker.rb` | `` `docker exec #{container.name} ps -eo comm=` `` | 同上 |
| `entrypoint.sh` | `sed -i "s\|TOKEN\|${GITLAB_TOKEN}\|g"` | token 含 `\|` 时断 |

**修复方案**：替换为 `Open3.capture3` 或 `system()` 数组形式。

### 2. 三处重复的模式
| 模式 | 出现位置 |
|------|---------|
| Volume 创建 `%w[kyb-gradle-cache ...]` | `docker.rb:233`, `did.rb:88`, `infra.rb:102` |
| DID 子容器清理 | `docker.rb`, `exit_flow.rb`, `manage.rb` |
| project-branch 解析 + auto_detect | `cli.rb` 5 处 |
| Stale image 提示 | `create.rb`, `enter.rb` |
| 容器就绪轮询 60×0.5s | `docker.rb`, `did.rb` |

**修复方案**：提取为共享 helper 方法。

### 3. `rescue Exception` / `rescue nil` 滥用
| 位置 | 问题 |
|------|------|
| `exit_flow.rb` | `rescue Exception` 吞了 SystemExit/SignalException |
| `proxy.rb` | 3 处 `rescue nil` / `rescue; next` — 吞一切 |
| `reporter.rb` | 错误只 warn 不处理 |
| `check.rb` | `rescue nil` 在 proxy_source 中 |
| `did.rb` | `did_parent_name` 用 `rescue nil` |

**修复方案**：`rescue Exception` → `rescue StandardError`，去掉不必要的 `rescue nil`。

### 4. Docker.run / create_container 超大方法
| 方法 | 行数 | 问题 |
|------|------|------|
| `Docker.run` | 115+ | 混合 DinD/non-DinD、mount、volume、port、proxy |
| `Docker.create_container` | 110+ | 混合验证、repo 设置、cp_files、image build、ready poll、tar pipe |
| `Config.project` | 50+ | 厨房水槽 — 加载+合并+回退逻辑混在一起 |

**修复方案**：按职责拆分。

### 5. 测试套件污染 — CI 红的根因
| 问题 | 影响 |
|------|------|
| `define_singleton_method` 永久替换 module_function | 跨测试文件污染 |
| `remove_method` 永久删除方法 | 后续测试 NoMethodError |
| `test_entrypoint.rb` 全 mock — 测的是 mock 不是代码 | 零回归检测能力 |
| `test_docker.rb` 创建真实 Docker volume | 副作用 |

**修复方案**：统一 teardown 模式（已修 3 个文件，还有 test_reporter.rb/test_metrics.rb 要修）。

---

## 按文件分解

### lib/kyb/check.rb — HIGH:3 / MEDIUM:5 / LOW:2
- 🔴 `capture_cmd` 反引号注入
- 🔴 `assert_java` 三层嵌套条件
- 🔴 `assert_pg` hardcode PG 16 + busy-wait 5s
- 🟡 `check_docker` 反引号
- 🟡 `check_disk` 解析 `df` 列索引
- 🟡 `check_endpoint` 不处理 query string
- 🟡 `capture_cmd` 无超时
- 🟢 `CmdResult` trailing newline
- 🟢 proxy hint 无关失败也显示

### lib/kyb/docker.rb — HIGH:4 / MEDIUM:5 / LOW:3
- 🔴 `run` 115 行超大方法
- 🔴 `create_container` 110+ 行
- 🔴 `ensure_master_synced` 破坏用户 repo 状态
- 🔴 Tar pipe shell 注入
- 🟡 `host_to_docker_proxy` 正则脆弱
- 🟡 `stale?` 吞所有异常
- 🟡 `port_in_use?` TOCTOU race
- 🟡 `containers_for_project` 反引号注入
- 🟡 `assign_ports` O(n²)
- 🟢 60 次轮询硬编码
- 🟢 volume create 无去重
- 🟢 DOCKER_BUILDKIT 始终设

### lib/kyb/exit_flow.rb — HIGH:2 / MEDIUM:3 / LOW:1
- 🔴 `rescue Exception`
- 🔴 反引号注入 (docker ps, docker exec)
- 🟡 `collect_extra_warnings` 进程白名单
- 🟡 `perform_cleanup` `rescue nil`
- 🟡 `interactive_delete_prompt` 非 TTY 不兼容
- 🟢 `docker rm -f` 返回值未检查

### lib/kyb/config.rb — HIGH:2 / MEDIUM:2 / LOW:2
- 🔴 `@config` 缓存无失效
- 🔴 `save` 非原子
- 🟡 `project` 厨房水槽
- 🟡 `build_cp_files` 在 Config 中 Kyb.die
- 🟢 `kyb_repo` nil 路径
- 🟢 `reporting_enabled?` rescue chain

### lib/kyb/reporter.rb — MEDIUM:3 / LOW:2
- 🟡 表名硬编码
- 🟡 session 事件写不同表
- 🟡 `http_post` 不检查 response body
- 🟢 无批处理
- 🟢 warn 输出到 stderr

### lib/kyb/tts_server.rb — MEDIUM:3 / LOW:3
- 🟡 voice 缓存无过期
- 🟡 `read_static` 无路径遍历保护
- 🟡 PORT 解析脆弱
- 🟢 Thread 无错误处理
- 🟢 bind 0.0.0.0
- 🟢 afplay macOS-only

### lib/kyb/parser.rb — MEDIUM:2 / LOW:1
- 🟡 `auto_detect` prefix match 歧义
- 🟡 `VALID_BRANCH_RE` 未在文档中说明
- 🟢 `container` 重复解析

### lib/kyb/cli/create.rb — HIGH:1 / MEDIUM:1 / LOW:1
- 🔴 project image build 两次
- 🟡 `create_diverse` 串行
- 🟢 stale 提示与 enter.rb 重复

### lib/kyb/cli/enter.rb — HIGH:1 / MEDIUM:1 / LOW:1
- 🔴 `ensure_container` 非 TTY 永不创建
- 🟡 stale 提示与 create.rb 重复
- 🟢 docker_exec_args 只调用一次

### lib/kyb/cli/manage.rb — HIGH:2 / MEDIUM:1 / LOW:1
- 🔴 `prune` 无确认直接删
- 🔴 DID 清理逻辑重复
- 🟡 `rm` 路径可能过期
- 🟢 `$stdin.gets` 非 TTY 阻塞

### lib/kyb/cli/did.rb — HIGH:1 / MEDIUM:4 / LOW:1
- 🔴 volume 创建代码重复
- 🟡 `did_parent_name` rescue nil
- 🟡 `fix_did_swift_path` sed 不可移植
- 🟡 容器名超长风险
- 🟡 60 循环 ready poll 重复
- 🟢 `sed -i` BSD/GNU 不兼容

### lib/kyb/cli/infra.rb — HIGH:4 / MEDIUM:2
- 🔴 docker run args 重复 docker.rb
- 🔴 `infra_enter` 重复 enter.rb
- 🔴 假定 kyb-infra-sing-box 存在
- 🔴 Claude binary path 遍历脆弱
- 🟡 symlink 到特定 mise 版本
- 🟡 硬编码体积名复制

### lib/kyb/cli/doctor.rb — MEDIUM:1 / LOW:1
- 🟡 cache volume regex `/kyb-.*-cache/` 过宽
- 🟢 已停止容器上 docker exec

### lib/kyb/cli/morning.rb — MEDIUM:2 / LOW:1
- 🟡 `working/onboarding-batches.md` 在实际安装路径不存在
- 🟡 6 次子进程调用
- 🟢 多个 rescue StandardError

### lib/kyb/cli/tts.rb — MEDIUM:2 / LOW:1
- 🟡 PID 文件管理不稳
- 🟡 `tts_stop` 缺 EACCES 处理
- 🟢 notify 硬编码端口

### entrypoint.sh — HIGH:4 / MEDIUM:8 / LOW:3
- 🔴 `userdel -r` 删除系统用户 home 目录
- 🔴 `chown -R dev:dev /home/dev` 影响 bind mount
- 🔴 sed 替换 GL_USER 分隔符冲突
- 🔴 CLAUDE.md heredoc 未引用
- 🟡 find+chmod 忽略不存在文件
- 🟡 pip install 文档注释说会失败
- 🟡 mise 内部路径遍历
- 🟡 `/etc/hosts` 服务别名硬编码
- 🟡 `git config --system` 绕过项目级配置
- 🟡 `exec runuser` 空 CMD 时与 sleep 冲突
- 🟢 `set -e` + `|| true` 组合
- 🟢 `rm -f` glob 可能展开为空
- 🟢 `grep "postgres"` 子串匹配

### Dockerfile — MEDIUM:5
- 🟡 22 个 RUN 层
- 🟡 Nexus 凭证硬编码
- 🟡 工具版本硬编码 (node@25, python@3.11 等)
- 🟡 kimi version 设了但没用
- 🟡 Aliyun 源假定 Ubuntu 24.04

### .gitlab-ci.yml — MEDIUM:3
- 🟡 测试排除列表硬编码
- 🟡 内部 registry 依赖
- 🟡 单进程跑全部测试，状态污染

---

## 修复优先级建议

| 波次 | 目标 | 理由 |
|------|------|------|
| **Wave 1** | Shell 注入面（6 处） | 真安全漏洞 |
| **Wave 2** | 测试污染（test_metrics 等） | CI 绿了才敢重构 |
| **Wave 3** | 三重复模式提取 helper | 消除熵的主要来源 |
| **Wave 4** | rescue Exception → StandardError | 错误不该沉默 |
| **Wave 5** | Docker.run/create_container 拆分 | 降低修改成本 |
| **Wave 6** | Config 原子 save + 缓存失效 | 数据安全 |
| **Wave 7** | 剩余 LOW/MEDIUM 扫尾 | 完善 |
