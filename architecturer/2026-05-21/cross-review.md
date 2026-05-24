# Cross-Review 模式发现

**日期：** 2026-05-21

## 事件

`check.rb` 被独立的 reviewer agent 审查，发现了 6 个 bug：

1. Shell 注入漏洞——用户输入直接插进 shell 命令
2. `assert_mise_tool` 在非交互式 shell 中完全失效
3. 若干错误处理边界情况
4. 更多...

## 洞见

> Review agent 比 implementer 做得更好。这不代表 implementer 差——这说明**把实现和审查分开能抓住更多问题。**

两双眼睛，两种视角。Reviewer 能发现 implementer 陷得太深而看不到的问题。

## 从此成为铁律

实现和审查绝不能用同一个 agent。这个模式贯穿了之后的每次大规模操作：
- 05-23 审计：3 人交叉验证
- 05-23 夜：每方向 3 人独立调研
- 打标阶段 3+3 交叉验证
