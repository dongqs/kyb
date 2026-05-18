# kyb 自身迭代踩坑记录

kyb 工具本身的改进过程中遇到的问题和教训。

## 构建与镜像

### 1. Dockerfile 缓存链断裂

**现象**：改一行 `mise.config.toml`，整个镜像重 build 10+ 分钟。

**根因**：`COPY mise.config.toml` 在第 63 行，其后的全部层（mig25、kimi、playwright 等）都被级联失效。

**教训**：易变配置（toolchain 版本）不应放在 Dockerfile 上半段。
详见 `docs/build/docker-cache-optimization.md`。

### 2. 宿主机与容器内 kyb 仓库不一致

**现象**：改了 `Dockerfile` 后 build，Maven 没打进镜像。查半天发现 `kyb build` 用的路径是 config.yml 里的 `base.image`，指向 `/Users/dongqs/github/kyb`，而我改的是容器内挂载的 `/home/dev/projects/kyb`。**两个不同的 clone**。

**根因**：config.yml 的 `base.image` 指向了 macOS 宿主机上的另一个 kyb 仓库路径。

**修复**：
```bash
# 从容器内同步到宿主机 build context
cat Dockerfile | docker run --rm -i -v /Users/dongqs/github/kyb:/repo alpine tee /repo/Dockerfile > /dev/null
```

**教训**：kyb 容器内开发时，改了 Dockerfile 记得同步到宿主机 build context。或者在宿主机直接改。

### 3. 基础镜像层的持久化

**现象**：`kyb build` 打出的镜像的某些文件（如 `~/.m2/settings.xml`）在新容器中经常"丢了"或路径不对。

**根因**：Dockerfile 中使用 `~` 展开为用户 home。确认 `USER dev` + `WORKDIR /home/dev` 后 `~` 正确展开为 `/home/dev`。

**教训**：涉及非 root 用户的 Dockerfile RUN，始终确认当前 USER。用 `~` 时可改用 `$HOME` 或显式路径。

## 容器生命周期

### 4. `kyb rm` 不清理共享 volume

**现象**：`kyb rm` 删除了 `*-claude` volume 和 `*-worktree` volume，但 `kyb-maven-cache`、`kyb-gradle-cache` 等共享 volume 保留。

**设计意图**：这些共享 volume 跨容器持久化，设计上就不删除（所有项目共享同一组）。

**副作用**：`kyb-maven-cache` 中多个项目的依赖混在一起。一个项目的 `chown` 没做好，下一个项目就报 `AccessDeniedException`。

**修复**：entrypoint 中统一 `chown -R dev:dev /home/dev/.m2/repository /home/dev/.gradle`。

**教训**：共享 volume 的权限问题必须在 entrypoint 层解决，不能依赖每个项目手动处理。

### 5. 子模块文件在 `docker cp` 后为空

**现象**：kyb 在 DinD 模式下用 `docker cp` 复制 worktree 到容器。但 worktree 中 `git submodule` 的内容不在 `.git` 目录管理下，copy 过去只有空目录。

**根因**：git submodule 的文件在 `git submodule update --init` 后才出现。worktree 初次创建时 submodule 未 init。

**修复**：在宿主机 worktree 中 `git submodule update --init --recursive`，再 `docker cp`。

**教训**：仅首次需要。后续 `kyb rm` + `kyb create` 重建后，`/home/dev/.git/modules` 持久化，子模块自动就绪。

## 配置管理

### 6. `~/.config/kyb/config.yml` 只读挂载

**现象**：容器内 `kyb init` 写配置失败，`~/.config/kyb` 被 `:ro` 挂载。

**绕行**：通过 Docker socket 起临时容器写宿主文件：
```bash
docker run --rm -v /Users/dongqs/.config/kyb:/config alpine sh -c "echo 'project: ...' >> /config/config.yml"
```

**教训**：需要实现 `kyb config` 子命令，内部自动处理 `:ro` 问题。

## 文档与流程

### 7. 两个 kyb 仓库的混淆

**现象**：新开发者在宿主机和容器内各有一个 kyb clone，不知改哪个。
宿主机的在 `/Users/dongqs/github/kyb`（build context），容器内在 `/home/dev/projects/kyb`。

**建议**：统一使用一个路径。或确保 `base.image` 指向的就是容器内挂载的 repo。

### 8. CLAUDE.md 与 .kyb.md 的分工

**现象**：agent 经常读错文档——在 kyb 工具仓库里找项目 onboarding 步骤。

**修复**：kyb 根目录加 `kyb/.kyb.md`，第一行就说"看错地方了"。

**教训**：两种文档的分工需要显式声明：
- `CLAUDE.md` → 工具开发指南
- `.kyb.md` → 项目 onboarding 流程
