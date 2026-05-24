# 9 MR 合入 master

**日期：** 2026-05-23

## 已合入

| MR | 内容 | 类别 |
|----|------|------|
| !120 | Heredoc 注入修复 `<< YAML` → `<< 'YAML'` | 安全 |
| !121 | doctor 命令接线（3 行） | 功能 |
| !122 | HTTPS_PROXY 文档（Go 程序需 HTTPS_PROXY 而非 ALL_PROXY） | 文档 |
| !123 | Branch 名校验 `/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/` | 输入校验 |
| !125 | morning require_relative 补加（修 crash） | bug 修复 |
| !126 | 删 GRADLE_CACHE_VOLUME / MAVEN_CACHE_VOLUME 常量 | 死代码 |
| !127 | 全面健壮性审计报告（25 HIGH / 40 MEDIUM / 30 LOW） | 文档 |
| !129 | Shell 注入修复 `Open3.capture3('sh', '-c', cmd)` | 安全 |

## 流程验证

Step 1 (Heredoc 注入修复) 验证了 3-reviewer 流程：
- 改 entrypoint.sh 一行
- `bash -n` 语法验证
- 3 人并行审查 → 全票通过

## 同时推进中

- Tebako 二进制打包（编译 CRuby + libdwarfs）
- kyb build 优化调研
- Go 重写调研（见 [go-vs-tebako](go-vs-tebako.md)）
