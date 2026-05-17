# kyb 异步构建方案设计

## 背景

`kyb create` 之前每次创建容器都会先执行 `kyb build` 重建镜像。这个过程耗时长、依赖网络/镜像源可用性，一旦 build 卡住（镜像源不可用、网络超时等），所有开发流程被阻塞。

## 已实施的改动

**`kyb create` 不再自动 build** — 现在只检查 `kyb-base:latest` 是否存在，不存在则提示先跑 `kyb build`。tag 是指针，下次 `kyb build` 成功更新 latest 后，新创建的容器自动用新镜像。

相关 commit: `c6635bc`

## 设计原则

1. **Build 与 Create 解耦** — build 失败不影响创建新容器
2. **异步迭代** — build 可以慢慢跑、失败重试、随时暂停调整
3. **原子切换** — build 成功后才更新 `kyb-base:latest` tag
4. **容器内闭环** — build 所有操作（编辑 Dockerfile → docker build → git commit）可在容器内完成

## Dockerfile 过长问题

当前 `Dockerfile` 144 行，各层间存在以下问题：

1. **逻辑混在一起** — 系统包、工具安装、项目配置、镜像源全部揉在一个文件
2. **层顺序不合理** — 缓存利用率低，改一处影响大片（如 `mkdir -p` 孤悬第 103 行）
3. **缓存样板代码重复** — 每个 `--mount=type=cache` 的 RUN 都要 `sudo mkdir + chown`

### 目标：三分层 + 按变化频率分离

| 层 | 文件名 | 内容 | 变化频率 |
|---|---|---|---|
| 系统层 | `Dockerfile.base` | Ubuntu + apt + PostgreSQL + locale + dev 用户 + mise 安装 | 几乎不变 |
| 工具链 | `Dockerfile.tools` | COPY mise.config.toml → GraalVM 预缓存 → `mise install` | mise.config.toml 变化时 |
| 最终层 | `Dockerfile` | 镜像源配置 + bundle/yarn config + kimi-wrapper + entrypoint | 相对频繁 |

### 项目工具运行时安装

以下工具从 Dockerfile 移除，改为 entrypoint 首次运行时安装（每个容器独立缓存，互不干扰）：

- `pip install mig25 mig25-codegen requests[socks]`（从 base 移出）
- `curl https://code.kimi.com/install.sh \| bash`（从 base 移出）
- `pip install playwright && python -m playwright install chromium --with-deps`（从 base 移出）
- `npm install -g puppeteer`（从 base 移出）
- Gradle Nexus 凭据 / npm/pip/gem 镜像源 → 保持或移到 entrypoint

### 缓存目录集中化

当前 BuilderKit cache mount 的样板代码：
```
RUN --mount=type=cache,target=/path \
    sudo mkdir -p /path && \
    sudo chown -R dev:dev /parent && ...
```

在 Dockerfile.tools 末尾加入一条 `USER root` 一次性创建所有 cache 目录（mise downloads / pip / uv / ms-playwright），后续各 RUN 省去 sudo 样板。

最终 Dockerfile 从 144 行 → ~70 行。

## Builder 容器方案

### 创建方式

手动在宿主机创建 builder 容器：

```bash
docker run -d --name kyb-builder \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/kyb:/home/dev/projects/kyb \
  kyb-base:latest sleep infinity
```

或通过 `kyb create` 将 kyb 项目注册到 config.yml 后创建。

### 容器内可完成的操作

| 操作 | 方式 |
|------|------|
| `docker build -t kyb-base:<ts> .` | Docker socket 挂载 |
| `docker tag kyb-base:<ts> kyb-base:latest` | 同一 socket |
| 编辑 Dockerfile / entrypoint / config | 源码挂载 |
| git commit / push | SSH key + gitconfig 已挂载 |
| 重试 build、换镜像源、调试 | Claude Code 交互 |

### 不需要回宿主收尾的操作

所有 build 相关操作在容器内闭环。宿主机只需启动容器时挂载 `~/kyb`。

## 未来方向

- 时间戳 tag：`kyb-base:YYYYMMDD-HHMM` + 更新 `kyb-base:latest`
- Dockerfile 分层拆分（系统层 / 工具链 / 项目工具）
- 项目工具运行时安装（mig25、kimi、playwright 等）而非打包进镜像
- 缓存目录集中管理（减少 `sudo mkdir + chown` 样板代码）
