# Boss 重生

**日期：** 2026-05-23
**背景：** 全面体检发现当前容器不够健壮

## 困局

Boss 三兄弟：
- **kyb-infra-boss-old** — 挂着 nuc8 SSH 隧道（走 GitLab 路由），不能杀（杀了隧道就断了），但缺 `--init`
- **kyb-infra-boss** — 当前活动会话
- **kyb-infra-boss2** — 唯一符合规范的容器（有 tini + 4GiB）

旧 boss 不能杀，但旧 boss 不健壮。

## 决策：不够健壮，重建

三个理由：
1. 无 `--init` → 过夜几十个僵尸
2. 无内存限制 → 子 agent 跑偏炸穿宿主
3. 镜像 dangling → 崩了起不来

用户说：你改名，我拉新的。

## 重生流程

1. 当前 boss 把自己从 `kyb-infra-boss` 改名为 `kyb-infra-boss-fallback`——容器内 `mv`，进程不受影响，名字空出来
2. 用户拉新的 `kyb-infra-boss`
3. 在 fallback 里写日记 + 快速上手指南（`docs/infra/NEW-BOSS-QUICK-REF.md`）

## 遗留

- 离开前写了快速上手指南留给新 boss
- 未修完的 P1 ~6 项
