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
