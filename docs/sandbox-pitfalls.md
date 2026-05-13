# kyb sandbox 实现踩坑记录

实现 `kyb sandbox`（宿主机直跑 Claude Code sandbox）过程中遇到的核心问题和解决方案。

## 1. `--sandbox` CLI flag 不存在

**现象**：`claude --sandbox` 报 `unknown option`。

**原因**：Claude Code 沙箱不是通过 CLI flag 启用的，而是通过 `.claude/settings.json` 中的 `sandbox.enabled: true` 配置。项目级 settings 自动被发现并合并到全局设置。

**解决**：在 worktree 下写 `.claude/settings.json`：
```json
{
  "sandbox": { "enabled": true },
  "permissions": { "allow": ["*"] }
}
```

## 2. `--dangerously-skip-permissions` 弹出确认警告

**现象**：每次启动弹 "WARNING: Claude Code running in Bypass Permissions mode"，需要手动确认。

**原因**：Claude Code 对 bypass permissions 模式有安全提示，需要显式跳过。

**解决**：在 settings.json 中加 `"skipDangerousModePermissionPrompt": true`。

## 3. 网络域名提示

**现象**：`npm install` 触发 "Network request outside of sandbox" 提示，需要手动允许 `registry.npmjs.org`。

**原因**：Sandbox 代理默认拦截所有外部网络请求，新域名需要用户审批。这是 sandbox 层面的提示，不受 `permissions.allow: ["*"]` 控制。

**解决**：两管齐下：
- `sandbox.network.allowedDomains` 预填常用域名（npm、GitHub、内部 GitLab 等）
- `npm install` 在 Claude 启动**之前**执行（不受 sandbox 限制），避免最常见的网络提示

## 4. macOS Seatbelt 阻断端口绑定

**现象**：`vite` 启动 dev server 报 `listen EPERM: operation not permitted 0.0.0.0:3000`。

**原因**：macOS Seatbelt 在 OS 内核层面阻断所有网络操作，只放行到 sandbox 代理端口的出站连接。`bind()` 系统调用被完全禁止，dev server 无法监听任何端口——即使绑定 `127.0.0.1` 也不行。

**解决**：将 dev server 命令加入 `sandbox.excludedCommands`，让它们在 sandbox 外执行：
```json
{
  "sandbox": {
    "excludedCommands": ["npm run *", "npx *", "vite", "next", "webpack"]
  }
}
```
其他命令（文件编辑、git 操作、npm install）仍在 sandbox 保护下。

## 5. 端口分配信息未传递给 dev 工具

**现象**：Claude 启动 dev server 时从 3000 开始逐个尝试，而不是直接用分配的端口。

**原因**：端口号写在了 CLAUDE.md 上下文里，但 Claude 没有把端口号传给 vite/npm 等子进程——这些工具不会读 CLAUDE.md。

**解决**：在启动 Claude 前设置 `PORT` 环境变量（`ENV['PORT'] = ports.first.to_s`），vite 等工具自动读取。

## 6. sandbox rm 后端口残留

**现象**：`kyb sandbox rm` 杀掉了 Claude Code 进程，但 dev server（vite）作为子进程仍在运行，端口未释放。

**原因**：`Process.kill` 只杀直接 PID，管不到 fork 出的孙子进程。

**解决**：在 `rm` 中用 `lsof -ti :PORT` 找到占用分配端口的进程，一并 kill。

## 总结

Claude Code sandbox 作为 OS 级安全边界是有效的，但在实际开发场景中有几个根本性限制：

| 问题 | 根因 | 是否可绕过 |
|------|------|:--:|
| 端口绑定被阻断 | Seatbelt 禁止 `bind()` | ✅ `excludedCommands` |
| 新域名需审批 | Sandbox 代理拦截 | ✅ `allowedDomains` 预填 |
| `--sandbox` flag 不存在 | 沙箱通过 settings.json 配置 | ✅ 写项目级 settings |
| bypass permissions 警告 | 安全提示 | ✅ `skipDangerousModePermissionPrompt` |
| 孙子进程端口泄露 | `Process.kill` 不递归 | ✅ `lsof` 清理 |

关键认知：**Claude Code sandbox 最适合"纯代码编辑"场景**（文件读写都在 worktree 内，出站网络走预批准的域名）。dev server、Docker 操作等需要网络监听或特殊权限的操作，应该通过 `excludedCommands` 排除，让它们跑在 sandbox 外。
