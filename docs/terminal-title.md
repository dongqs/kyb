# 终端标题清理尝试记录

目标：`kyb enter` 后外层 iTerm2 标签页标题显示 `kyb:container`（或含 Claude 状态），而非 `docker exec -it -u dev ...`。

## 链路

```
iTerm2 ← docker exec ← tmux ← bash ← claude
```

iTerm2 默认会把当前进程名（Job）追加到标题后面，无论程序怎么设 OSC `\e]0;...\a` 都会被覆盖。

## 试过的方法

### 1. exec 前用 Ruby 发 OSC `\e]0;...\a`
- **结果**：exec 后进程被替换，标题丢失。无效。

### 2. tmux `set-titles on` + `set-titles-string "kyb:container"`
- **结果**：tmux 设置标题后，iTerm2 立即用进程名覆盖。无效。

### 3. tmux `automatic-rename off` + `set-titles-string "#W"`
- **结果**：窗口名干净，iTerm2 仍追加 `docker exec ...`。无效。

### 4. tmux `#{pane_title}` 透传 Claude Code 标题更新
- **结果**：Claude 摘要出现了，但 `#{pane_title}` 被 docker exec / token 污染。无效。

### 5. `automatic-rename off` + `select-pane -T` 设初始 pane title + `#{pane_title}`
- **结果**：同上，docker exec 持续污染 pane_title。无效。

### 6. bash 内 `printf '\e]0;...\a'` 直接发 OSC
- **结果**：被 tmux 拦截作为 pane title，未透传到外层。无效。

### 7. 符号链接改名 docker 进程（`kyb-niao-water → /usr/local/bin/docker`）
- **结果**：iTerm2 仍然显示实际 argv 而非 symlink 名。无效。

## 结论

**根因在 iTerm2 Profile → General → Title → Job**，它用进程名覆盖一切标题设置。

- 修改该设置为 Custom 或关闭即可解决。
- 代码层面已经做到 tmux `#{pane_title}` 传播 Claude 状态摘要，只差 iTerm2 这一步。

## 相关文件

- `lib/kyb/cli/enter.rb` — 标题设置逻辑（tmux opts + symlink）

## 参考

- iTerm2: Preferences → Profiles → General → Title → 取消 Job 勾选
- tmux: `set-titles` / `set-titles-string` / `automatic-rename` / `allow-rename`
