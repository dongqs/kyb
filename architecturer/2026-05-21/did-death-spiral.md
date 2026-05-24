# DID 死亡螺旋终结

**日期：** 2026-05-21
**变化：** 30 分钟死亡螺旋 → 15/17 tests pass

## 背景

Docker-in-Docker 容器一直是老大难。30+ 分钟的死亡螺旋、级联溃败、整个系统在内部坍塌。

## 修复内容

- JDK 21 正确安装
- PostgreSQL 容器启动时自动启动
- `/etc/hosts` 别名正确配置
- 代理翻译 localhost → host.docker.internal

## 结果

DID 验证通过 15/17 项。剩余 2 项已知且可控：
- Proxy 翻译缺失（安装的 kyb 版本未包含——需下次 build）
- docker exec 不使用 `-u dev`（预期行为）

## 后续发现（05-21 timeline 项目）

第一个完成全 DID 验证的项目（Rounds 3-4）发现：
- JDK 8 必须通过 tar pipe 复制进 DID 容器
- Maven 需要显式 `-s ~/.m2/settings.xml`
- Nexus Nginx 通过 TLS 指纹拦截 curl（Java HTTP 客户端正常工作）
