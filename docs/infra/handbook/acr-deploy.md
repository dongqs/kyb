# ACR / 阿里云镜像仓库手册

## ACR 信息

| 字段 | 值 |
|------|-----|
| 地址 | crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com |
| 账号 | dongqs@gmail.com |
| 密码 | 见 `~/projects/kyb/.env` |

## Docker Registry Cache (sim)

在 sim 上运行的本地镜像缓存，用于加速 Docker 拉取：

```bash
# sim 上已运行
docker run -d --name kyb-registry-cache \
  --restart always \
  -p 5000:5000 \
  -v registry-data:/var/lib/registry \
  registry:2
```

## 推送镜像到 cache

```bash
# 用 helper 脚本
push-to-sim-mirror postgres:16-alpine
# 逻辑: docker pull → docker tag → docker push sim:5000/...
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| Docker Hub 连不上 | sim 国内网络被墙 | 必须在 sim 上走代理拉取 |
| ghcr.io denied | 需要 GitHub PAT | `docker login ghcr.io -u USERNAME --token-stdin` |
| ARM64/AMD64 不匹配 | sim 是 AMD64，开发机是 ARM64 | 拉取时指定 `--platform linux/amd64` |
| 50 块钱不够 | NAT 网关等太贵 | 用 registry cache 替代 |
