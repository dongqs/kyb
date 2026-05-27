# PostgreSQL 多版本部署手册

## 容器列表

| 版本 | 容器名 | 端口 |
|------|--------|------|
| 14 | kyb-infra-postgresql-14 | 5434 |
| 15 | kyb-infra-postgresql-15 | 5435 |
| 16 | kyb-infra-postgresql-16 | 5436 |
| 17 | kyb-infra-postgresql-17 | 5437 |

## Docker Run

```bash
docker volume create pg16-data
docker run -d --name kyb-infra-postgresql-16 \
  --network kyb-net --restart unless-stopped \
  -p 5436:5432 \
  -v pg16-data:/var/lib/postgresql/data \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:16-alpine
```

## 连接字符串

| 来源 | 连接串 |
|------|--------|
| kyb-net 内容器 | `postgresql://postgres@kyb-infra-postgresql-16:5432/postgres` |
| macOS 宿主机 | `postgresql://postgres@127.0.0.1:5436/postgres` |

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| 镜像拉不动 429 | docker.xuanyuan.me 限流 | `docker pull docker.1ms.run/library/postgres:16-alpine` 后重新 tag |
| 容器名冲突 "already in use" | 同名容器已存在 | `docker rm -f kyb-infra-postgresql-16` 再重跑 |
| 数据没了 | 没挂 volume | 必须 `-v pg16-data:/var/lib/postgresql/data` |
| 连不上 `trust auth` | 没设 `POSTGRES_HOST_AUTH_METHOD=trust` | 加环境变量 |
| 时间不对 | 没设 `TZ=Asia/Shanghai` | 加环境变量 |
