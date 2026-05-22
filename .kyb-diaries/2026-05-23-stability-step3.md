# 稳定性推进日记 — Step 3: Branch 名校验

**日期：** 2026-05-23

## 流程

调研 → 实现 → 3 审稿人 → 修错误信息 → MR → 合 → 日记

## 变更

**位置：** `lib/kyb/parser.rb:6-42`
**问题：** branch 名无校验，`/`、`@`、前导点等字符可进入 Docker 容器名
**修复：** 
- 添加 `VALID_BRANCH_RE` 正则（匹配 Docker 容器名规范）
- `parse` 方法中提取 branch 后调用 `validate_branch!`
- 错误信息用自然语言（reviewer 指出后修复）

**测试：** 新增 5 个测试用例（斜杠、@、点、空、正常）

## MR

!123 — fix: add branch name validation to Parser.parse

## 当前 master 状态

| MR | 内容 | 状态 |
|----|------|------|
| !118 | 隔壁修 test_reporter.rb | ✅ |
| !120 | Heredoc 注入修复 | ✅ |
| !121 | doctor 命令接线 | ✅ |
| !122 | HTTPS_PROXY 文档 | ✅ |
| !123 | Branch 名校验 | ✅ 刚合 |
