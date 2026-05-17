# kyb 沙箱 Swift 测试

`Dockerfile.swift` 在 kyb-base 上叠加 Swift 工具链，用于容器内跑 niao 项目 `swift-core/Tests/`。

## 构建

```bash
docker build -t kyb-swift -f Dockerfile.swift <niao-worktree-path>
```

## 已知问题（2026-05-17）

| 问题 | 现象 | 根因 |
|------|------|------|
| GitHub 认证 | `mise plugin install swift` 报 `Failed to obtain credentials` | Docker build 无交互终端，GitHub HTTPS 要求认证 |
| Swift.org CDN | download.swift.org 下载 URL 全部返回 404 | 官方 CDN 疑似下线/改路径 |
| Swift Docker 镜像 | `docker pull swift:6.0 --platform linux/arm64` 超时 | 网络或镜像不可达 |

## 下次尝试方向

1. 确认 swift.org 下载是否已恢复，或改用国内镜像
2. 宿主机本地下载 Swift 工具链 tarball，`docker build` 时 COPY 进去
3. 查 Ubuntu 24.04 官方 apt 包：`apt install swiftlang`
4. swift-core 测试直接宿主机 Xcode 跑（macOS 自带 Swift）
