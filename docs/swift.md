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
