# race-worker — 服务层

## Docker

| 项目 | 状态 |
|------|------|
| Docker CLI | 29.1.3 (已安装) |
| Docker Compose | 2.40.3+ds1 |
| Docker Server | **不可用** (/var/run/docker.sock 不存在) |
| 运行中容器 | 无 (无法连接 Docker daemon) |
| 镜像 | 不可查 |

- 有 Docker CLI 客户端但无 Docker daemon 访问权限
- 此容器本身就是一个 Docker 容器，可通过宿主机的 Docker socket 使用 Docker 功能？

## 数据库客户端 (已安装)

| 数据库 | 客户端版本 |
|--------|-----------|
| PostgreSQL | 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1) |
| ClickHouse | 26.4.2.10 (official build) |

## 数据库服务 (监听)

| 端口 | 服务 | 状态 |
|------|------|------|
| 5432 | PostgreSQL | 未监听 |
| 3306 | MySQL | 未监听 |
| 6379 | Redis | 未监听 |
| 8123/9000 | ClickHouse | 未监听 |
| 27017 | MongoDB | 未监听 |

- **本地无数据库服务运行**
- 仅 SSH (22) 是唯一监听端口
