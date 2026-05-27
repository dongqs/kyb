# 稳定性推进日记 — Step 1: Heredoc 注入修复

**日期：** 2026-05-23

## 流程验证

3 审稿人独立审查 → 全票通过 → 推 GitLab → 更新日记

```
1. 改一行 entrypoint.sh (<< YAML → << 'YAML' + sed 替换)
2. bash -n 语法验证
3. 派 3 人并行审查
4. 3/3 PASS → 推 fix/heredoc-quote
5. master 保护分支不能直推 → 等 glab 网络恢复后合 MR
```

## 变更

**位置：** `entrypoint.sh:129-142`
**问题：** 未引用 heredoc，GITLAB_TOKEN 含特殊字符时可触发 shell 注入
**修复：** 
- 引号 heredoc `<< 'YAML'` 防止 shell 展开
- 占位符 `GL_USER_PLACEHOLDER` / `GITLAB_TOKEN_PLACEHOLDER` 写完后用 `sed` 安全替换
- sed 分隔符 `|` (hex token 不含 `|`)

## 下一步

按优先级挑下一个微小修复。
