# 稳定交接

**日期：** 2026-05-24
**目标：** 以后回来的人不用再踩一遍之前的坑

## 当前稳定状态

| 服务 | 健康 | 依赖 |
|------|------|------|
| `kyb-infra-sing-box` | ✅ restart:always，端口映射，kyb-net | 无 |
| `kyb-infra-boss` | ✅ 随用随建，auto-recovery | sing-box（代理）|
| nuc8 隧道 | ✅ autossh 保活 | sim 在线、nuc8 在线 |
| GitLab | ✅ 全链路通 | sing-box → nuc8 隧道 |
| 宿主机代理 | ✅ `127.0.0.1:2080` → sing-box | sing-box 运行中 |

## 已知未修

1. `entrypoint.sh` 无自动修 sing-box 配置（.17→.3）逻辑
2. 所有容器缺 `NO_PROXY`
3. 所有容器缺 `--init`
4. 所有容器无内存限制

## 平稳运行检查清单

```bash
# 1. 容器都在
docker ps --filter name=kyb-infra

# 2. 代理通
curl -x socks5://127.0.0.1:2080 -sI https://github.com
curl -x socks5://127.0.0.1:2080 -sI https://git.leyantech.com

# 3. 隧道在
docker exec kyb-infra-boss ss -tlnp | grep 2081

# 4. GitLab API 通
docker exec kyb-infra-boss curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  https://git.leyantech.com/api/v4/version

# 5. 磁盘够
df -h /
```
