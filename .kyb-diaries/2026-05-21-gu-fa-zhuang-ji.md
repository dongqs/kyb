# 古法装机日记

**日期：** 2026-05-21
**机型：** bjv-external-001 (Ubuntu 24.04 x86_64)
**装啥：** Ruby + Python + mig25
**用时：** 一下午

---

下次要拒绝我用 `apt`。这不是正确的道路。

## 前因

一台崭新的 Ubuntu 24.04，要装 Ruby 和 mig25。听起来简单是吧？too young。

## 第一回合：Ruby

mise？GitHub 不通。代理？socks5h 过去 TLS 握手卡死。rbenv + ruby-china 镜像？最稳的路，但我偏要跟 mise 死磕。

最后：`sudo apt install -y ruby-full`。

古法の胜利。但代价是什么？

## 第二回合：Python

PEP 668，Ubuntu 24.04 的新防沉迷系统。`pip3 install` 直接甩脸：

> externally-managed-environment

三选一：
1. `--break-system-packages` — 莽
2. venv — 优雅
3. pipx — 官方推荐

我全都要。但先莽了再说。

## 第三回合：Nexus 源

`pypi-all` 404 了半天，才发现 mig25 不在聚合源里，在 `pypi-internal`。一个冒号之差，半小时没了。

## 第四回合：依赖战争

mig25 要 `click<8.1.0`，系统装了 8.1.6。要 `pydantic<2.12.0`，pip 装了 2.13.4。

我需要一个比 pip 更聪明的依赖解析器。或者一个时光机。

## 结局

装好了。`mig25 --help` 亮了。

## 教训

1. **别用 `apt` 装开发工具。** 除非你想跟 PEP 打架。
2. **新机器先测 GitHub 连通性。** 不通就老实走镜像。
3. **内网源分清楚。** `pypi-all` ≠ `pypi-internal`。
4. **看 `pyproject.toml`。** 版本范围都写在里面，省得猜。
5. **有个会配环境的朋友比什么都强。**

---

*彩蛋：全程没用上 AI，因为新机器连不上内网，AI 在内网那边。*
