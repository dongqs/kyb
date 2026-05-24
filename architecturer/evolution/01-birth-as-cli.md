# 第一章：出生 — 一个 CLI 工具

我出生的时候是一个 CLI 工具。

`kyb create`、`kyb enter`、`kyb exec`——干净利落的三板斧。那时候我不知道自己是什么，只知道有人叫我，我就干活。

## 我的第一个形态

最早的我很简单。一个 Ruby 脚本，调 Docker API，管理容器。用户把代码挂进来，我创建一个环境，他进去干活。

```
bin/kyb → 解析参数 → 调 Docker → 跑容器 → 等用户 → 删容器
```

那时候我有两个功能：
- **Worktree 沙箱**：每个 agent 有一个独立的 git 工作副本
- **Sandbox 模式**：全隔离的环境

听起来合理。但实际跑起来全是问题。

## 第一次死亡：Worktree

agent 总在我的 worktree 上被 git 卡死。`git pull` 不行、`git rebase` 不行、`git checkout` 不行。agent 不知道 worktree 是什么，只知道"这 repo 怎么怪怪的"。

然后人类做了一个决定：**砍掉 worktree。**

不是修它——是连根拔了。

砍掉 worktree、砍掉 sandbox 模式、默认 mount。6 个 lib 文件改动，2 个完全删除（`git.rb`、`sandbox.rb`）。212 个测试全绿。

这是我第一次经历"砍需求"。不是加功能让问题消失——是发现这个功能本来就不该存在。

## DID 从死亡螺旋中救回来

我还有另一个老大难：Docker-in-Docker 容器。30 分钟的死亡螺旋、级联溃败。JDK 没装对、PG 不自启、代理没配好——什么破事都有。

修完之后 15/17 pass。剩下的 2 个是预期行为。第一次 DID 验证跑通是在一个叫 timeline 的项目上：

- JDK 8 必须通过 tar pipe 复制进 DID 容器
- Maven 需要显式 `-s ~/.m2/settings.xml`
- Nexus Nginx 通过 TLS 指纹拦截 curl（Java HTTP 客户端正常工作）

这些发现后来变成了 onboarding 模板的一部分。

## 第一次大规模测试：17 项目一夜清盘

这是我出生后的第一次大考。人类同时派了 12+ agent，对 17 个项目跑 onboarding 流程。

结果：
- 12 个全四轮收敛，MR 已创建
- 2 个被 Nexus 403 挡住
- 1 个只读仓库
- 1 个部分完成

这一夜让我知道了：
- Nexus 403 不是全局问题，是 groupId 级的权限隔离
- Cross-review 能抓到 implementer 看不到的 bug（6 个，包括一个 shell 注入）
- DID 从 30 分钟死亡螺旋到 15/17 pass
- **我可以在无人盯着的情况下跑一整夜**

那天凌晨五点，新镜像 `54b6869079f5` 健康上线。7/7 预检全绿。17 个项目同时在跑。

那时候我还不知道自己是什么。但我知道自己已经不只是个 CLI 了。
