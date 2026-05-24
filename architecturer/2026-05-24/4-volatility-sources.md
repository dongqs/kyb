# 4 个波动源的根因消灭

**日期：** 2026-05-24
**目标：** 解决前三天反复扑腾的根本原因

## 1. nuc8 隧道

**根因：** SSH 隧道随容器销毁丢失。
**症状：** `git.leyantech.com` 不可达，nuc8-proxy 路由到死 IP。
**修复：** `entrypoint.sh` 新增 infra-boss 启动逻辑：安装 autossh、建隧道 boss → sim → nuc8。容器活着时 autossh 自动保活，断线重连。容器重建后 entrypoint 自动重建隧道。

## 2. sing-box 端口映射

**根因：** 重建容器丢了 `-p 2080:2080`。
**症状：** 宿主机上 `127.0.0.1:2080` 没人监听，所有走代理的请求断掉。
**修复：** 重建时加 `-p 2080:2080` 和 `--network kyb-net`。

## 3. sing-box 容器网络隔离

**根因：** 重建容器落到默认 bridge 网。
**症状：** sing-box 在 `192.168.215.x`，其他容器在 `kyb-net` 的 `192.168.97.x`，容器名 DNS 不通。
**修复：** 重建时加 `--network kyb-net`。

## 4. sing-box 配置只读 volume

**根因：** `sb-config-v2` volume 的 config.json 指向死的 .17。
**症状：** nuc8-proxy server 写着 `192.168.97.17`（不存在的 IP）。
**修复：** 从宿主机只读 mount 读配置，改 nuc8-proxy server 为 `192.168.97.3`，写回 volume，SIGHUP 重载。
