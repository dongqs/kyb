# 全面健壮性审计

**日期：** 2026-05-23
**扫描范围：** `lib/kyb/*.rb`, `test/*.rb`, `entrypoint.sh`, `Dockerfile`, `.gitlab-ci.yml`

## 统计

**总计：25 HIGH / 40 MEDIUM / 30 LOW = 95 项**

按文件分解：

| 文件 | HIGH | MEDIUM | LOW |
|------|------|--------|-----|
| `check.rb` | 3 | 5 | 2 |
| `docker.rb` | 4 | 5 | 3 |
| `exit_flow.rb` | 2 | 3 | 1 |
| `config.rb` | 2 | 2 | 2 |
| `entrypoint.sh` | 4 | 8 | 3 |
| `Dockerfile` | 0 | 5 | 0 |
| 其他 | 10 | 12 | 19 |

## 五大高杠杆目标

### 1. Shell 注入面 — 6 处
`check.rb`、`docker.rb`、`exit_flow.rb`、`entrypoint.sh` 中共 6 处用户输入直拼 shell

### 2. 三处重复模式
Volume 创建、DID 清理、project-branch 解析、stale 提示、容器就绪轮询

### 3. `rescue Exception` / `rescue nil` 滥用
`exit_flow.rb`、`proxy.rb`、`reporter.rb`、`check.rb`、`did.rb`

### 4. Docker.run / create_container 超大方法
`Docker.run` 115 行，`create_container` 110+ 行

### 5. 测试套件污染
`define_singleton_method` 永久替换 module_function，`remove_method` 永久删除方法

## 修复优先级

| 波次 | 目标 | 状态 |
|------|------|------|
| Wave 1 | Shell 注入 6 处 | ✅ 已修 |
| Wave 2 | 测试污染 | ⏳ 部分已修 |
| Wave 3 | 重复模式 | ❌ |
| Wave 4 | rescue Exception | ❌ |
| Wave 5 | 超大方法拆分 | ❌ |
