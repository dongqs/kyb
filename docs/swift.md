# kyb 沙箱 Swift 测试

通过 `kyb-swift-cache` 命名 volume 共享 Swift 6.2 工具链。

## 工作原理

- `kyb did create` 自动检测 `kyb-swift-cache` volume 并挂载到 DID 容器的 `/home/dev/.local/swift`
- 工具链解压后 4.1GB（压缩包 ~950MB），volume 持久化在宿主机
- 容器启动后需手动配置 PATH：`export PATH=/home/dev/.local/swift/usr/bin:$PATH`

## 使用

具体步骤详见下游项目的 `.kyb.md`：

- [niao 的 kyb DID 流程](https://github.com/dongqs/niao/blob/master/.kyb.md)

## 维护缓存

```bash
# 查看缓存是否存在
docker volume ls -q --filter name=^kyb-swift-cache$

# 清除重建
docker volume rm kyb-swift-cache
# 然后按下游项目 .kyb.md 的「无缓存时的手动下载」重新创建
```

## 历史踩坑记录

### 尝试 1：Dockerfile.swift 构建 kyb-swift 镜像

在 kyb-base 上叠加 Swift 工具链：

```dockerfile
FROM kyb-base
RUN mise plugin install swift https://github.com/mise-plugins/mise-swift.git && \
    mise install swift@6.2
```

**结论：❌ 受阻**
- `mise plugin install swift` 在 Docker build 无交互终端时报 `Failed to obtain credentials`（GitHub HTTPS 要求认证）
- `download.swift.org` 下载 URL 偶发 404，CDN 不稳定
- `docker pull swift:6.0 --platform linux/arm64` 超时

### 尝试 2：mise plugin 容器内安装

容器启动后 `mise install swift@6.2`（不经过 build）。

**结论：❌ 踩坑**
- 需要 `mise settings experimental=true`（否则最后一步报错，已修复）
- 从 `download.swift.org` 直连 ~1.5MB/s，但大文件经常中途断连重试
- 代理（SOCKS5）更不稳定，多次断连后自动重启下载
- 每次新建容器都要重下 ~950MB，无法接受

### 尝试 3：apt install

```bash
apt install swiftlang
```

**结论：❌ Ubuntu 24.04 仓库中不可用。**

### 最终方案：volume 缓存 ✅

宿主机维护 `kyb-swift-cache` 命名 volume，预装 Swift 6.2（aarch64），
`kyb did create` 自动挂载，DID 容器秒级可用。

## DID 容器运行 Swift 测试的注意事项

### SSH 认证

`kyb did create` 会复制宿主机的 `~/.ssh/` 到 DID 容器，但 **known_hosts 中可能没有 GitHub**，
首次 SSH 连接会因 `Host key verification failed` 被拒。

**解决：** 以 `dev` 用户执行一次 SSH（`accept-new` 自动接受 host key）：
```bash
docker exec -u dev did-<name> ssh -o StrictHostKeyChecking=accept-new -T git@github.com
```

验证：
```bash
docker exec -u dev did-<name> ssh -T git@github.com 2>&1 | head -3
# 应输出：Hi dongqs! You've successfully authenticated...
```

### docker exec 用户

`docker exec` 默认以 `root` 用户进入容器，但 SSH 私钥（`600` 权限）属主是 `dev`，
root 无法读取。首次 clone 会因认证失败被拒。

**必须加 `-u dev`**：
```bash
docker exec -u dev did-<name> bash -c 'cd ~/projects/niao/swift-core && swift test'
```

验证（以 root 执行会失败，`-u dev` 正常）：
```bash
# ❌ 不加 -u 会失败
docker exec did-<name> bash -c 'cd ~/projects/niao/swift-core && swift test' 2>&1 | tail -3

# ✅ 加 -u dev 正常
docker exec -u dev did-<name> bash -c 'cd ~/projects/niao/swift-core && swift test' 2>&1 | tail -3
```

### PATH 配置

`~/.bashrc` 的结构是：
```
eval "$(mise activate bash)"      # 非交互式也能用
alias ...
[ -z "$PS1" ] && return           # ← 非交互式在这里 return
...
export PATH=...:/home/dev/.local/swift/usr/bin:$PATH   # ← 追加在末尾，非交互式不生效
```

Swift 的 `PATH` 如果追加在文件末尾，非交互式 shell（`bash -c`、`docker exec` 不分配 tty 时）
不会执行到。**必须插入到 `return` 守卫之前**：
```bash
sed -i '3iexport PATH=/home/dev/.local/swift/usr/bin:$PATH' ~/.bashrc
```

或者直接 `docker exec -u dev ... bash -l -c 'cd ... && swift test'`（login shell 会读所有配置）。

验证：
```bash
docker exec -u dev did-<name> bash -l -c 'swift --version'
# 应输出：Swift version 6.2 (swift-6.2-RELEASE)
```
