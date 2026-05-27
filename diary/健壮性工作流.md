# 健壮性修复工作流

> 适用场景：对现有项目进行系统性健壮性增强，维持功能不变的前提下消灭熵。
> 已验证于：kyb 项目（2026-05-23，~95 个 entropy 点）

---

## 核心原则

1. **每次只做一点点** — 一个 MR 只改一件事，越小越好
2. **三分交叉** — 实现者 ≠ 审稿人，审稿人之间独立，不共享
3. **流程闭环** — 调研 → 实现 → 审稿（≥2人） → MR → CI 绿 → 合 → 日记
4. **不动功能** — 只重构不新增，测试全绿是硬门槛
5. **文档同步** — 每步留日记，报告随时推

---

## 阶段划分

### Phase 0: 全面审计

派 Explore agent 扫描整个代码库，按维度分类：

```yaml
categories:
  shell_injection:     # 反引号 + 字符串插值
  dead_code:           # 未使用的常量/方法/文件
  duplicated_patterns: # 重复代码块
  error_handling:      # rescue Exception, rescue nil
  input_validation:    # 用户输入未校验
  test_pollution:      # 跨测试文件状态污染
  hardcoded_values:    # 魔数/魔串
  oversized_methods:   # >50 行方法
  non_atomic_ops:      # 文件写操作无原子性
  env_assumptions:     # macOS-only, Orbstack-only, China-only
```

输出：按 HIGH/MEDIUM/LOW 分级的完整清单

### Phase 1: 安全修复（HIGH）

先修真安全漏洞，其他都等：

```
1. Shell 注入   →  反引号 → Open3.capture3 + Shellwords.split
2. 测试污染    →  remove_method → save/restore 模式
3. CI 红       →  先让 pipeline 绿，否则所有 MR 被堵
```

每修一个立即合入 master，别攒。

### Phase 2: 去重提取（HIGH/MEDIUM）

识别重复次数最多的模式，提取共享 helper：

```
1. Volume 创建循环     → Kyb::Docker.ensure_cached_volumes
2. DID 子容器清理      → Kyb::Docker.cleanup_did_children
3. project-branch 解析  → Kyb::Parser.parse_or_detect
4. Ready 轮询          → Kyb::Docker.wait_ready(name, timeout: 30)
5. Stale image 提示     → Kyb::CLI.stale_image_warning(project)
```

不改变调用语义，只消除重复。

### Phase 3: 异常处理规范化（MEDIUM）

统一 rescue 模式：

```ruby
# BAD
rescue Exception   # 吞了 SystemExit
rescue nil         # 吞了一切，包括 typo

# GOOD
rescue StandardError => e
  warn "some_context: #{e.message}"
  nil
```

重点关注：`proxy.rb`, `reporter.rb`, `exit_flow.rb`, `check.rb`, `did.rb`

### Phase 4: 大方法拆分（MEDIUM）

识别 >50 行方法，按职责拆：

| 方法 | 当前行数 | 建议拆分 |
|------|---------|---------|
| `Docker.run` | 115 | `build_run_args` + `execute_run` + `post_run_checks` |
| `Docker.create_container` | 110 | `setup_repo` + `build_image` + `start_container` + `wait_ready` |
| `Config.project` | 50+ | `load_config` + `merge_defaults` + `build_cp_files` |

### Phase 5: 扫尾（LOW）

- 死代码删除
- 硬编码值抽常量
- 非原子操作加 fsync / 临时文件
- 文档同步更新

---

## 单步执行流程

每步严格按这个流程走，不跳步：

```
┌─────────────┐
│  1. 调研     │ ← Explore agent，读代码，确定改什么、怎么改
└──────┬──────┘
       ↓
┌─────────────┐
│  2. 实现     │ ← 一个 subagent，只改一个文件，只改一件事
└──────┬──────┘
       ↓
┌─────────────┐
│  3. 审稿×2~3 │ ← 独立 subagent，各自看 diff、跑测试、报结论
└──────┬──────┘
       ↓
┌─────────────┐
│  4. MR + CI  │ ← glab mr create → wait pipeline → glab mr merge
└──────┬──────┘
       ↓
┌─────────────┐
│  5. 日记     │ ← 更新 .kyb-diaries/YYYY-MM-DD-stepN.md
└──────┬──────┘
       ↓
┌─────────────┐
│  6. 下一步    │ ← 回到 1，从清单中取下一条
└─────────────┘
```

### 交叉派活规则

```
实现者 A 审 实现者 B 的代码
实现者 B 审 实现者 C 的代码
实现者 C 审 实现者 A 的代码

永不：实现者自己审自己
永不：同一个 agent 既实现又审
永不：复用之前的 agent（每次派新的）
```

### 审稿人检查清单

每个审稿人必须完成：

- [ ] `git diff glab/master..HEAD` 只包含目标改动？
- [ ] `bash -n entrypoint.sh`（如果是 shell 代码）
- [ ] 改动文件测试全绿
- [ ] 全量测试 0 failures, 0 errors
- [ ] 没有旁路路径（未保护的调用点）
- [ ] 错误信息对用户友好（不暴露正则/内部细节）

---

## 两个例外情况

### CI 红了怎么办

先查是什么导致失败：

```
1. 预存测试污染（如 remove_method 问题）→ 先修测试再合代码
2. 真是你的改动 break 了 → 修好再合
3. 基础设施问题（registry 挂、网络不通）→ 等修好再重跑
```

Pipeline must succeed 启用后，CI 红 = MR 不能合。所以 **Phase 1 先修测试污染**。

### glab API 挂了怎么办

```
glab 直连 → 403 WAF
解决：HTTPS_PROXY=socks5://host.docker.internal:2080 glab ...
```

SSH 直连 `git@git.leyantech.com` 不受 WAF 影响，`git push` 走 SSH 永远可用。

---

## 工具链

```bash
# 创建分支并推送
git checkout -b fix/<short-name>
git push glab HEAD:refs/heads/fix/<short-name>

# 创建 MR（代理）
HTTPS_PROXY=socks5://host.docker.internal:2080 glab mr create --title 'fix: ...'

# 合 MR
HTTPS_PROXY=socks5://host.docker.internal:2080 glab mr merge <MR_NUMBER>

# 跑测试
for f in test/test_*.rb; do ruby -Itest "$f"; done

# 审 CI 日志
TOKEN="<gitlab_token>"
curl -sx socks5://host.docker.internal:2080 \
  -H "PRIVATE-TOKEN: $TOKEN" \
  "https://git.leyantech.com/api/v4/projects/<project>/jobs/<JOB_ID>/trace"
```

---

## 指标

一个健康的项目应该：

| 指标 | 目标 |
|------|------|
| 全量测试 | ✅ 0 failures, 0 errors |
| CI pipeline | ✅ 绿 |
| Shell 注入面 | 0 处 |
| `rescue Exception` | 0 处 |
| `rescue nil`（非故意） | 0 处 |
| >50 行方法 | <5 个 |
| 三重复模式 | <3 处 |
| 测试跳过 | <10% |

---

## 复盘模板

每轮完成后，在 `.kyb-diaries/` 留日记：

```markdown
# 健壮性修复日记 — Step N: <标题>

日期：YYYY-MM-DD

## 变更

位置：<文件路径>
问题：<原本什么问题>
修复：<怎么修的>

## 流程

调研 → 实现 → N 审稿人 → MR → 合 → 日记

## MR

!<NUMBER> — <commit message>

## 剩余进度

当前累计：N/95 entropy 点消灭
下一目标：<下一步的计划>
```
