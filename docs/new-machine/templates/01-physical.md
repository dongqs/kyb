# 物理层 — {new-machine-remote-hostname}

我是谁：记录 remote:ssh {new-machine-ssh-user}@{new-machine-ssh-host} 的硬件信息。
我在哪：remote:~/.claude/docs/01-physical.md
我要干什么：描述硬件配置、磁盘布局、性能基准。
我不干什么：不记录 OS 配置、网络、运行服务。

## 当前状态

> 📝 操作提示：每个子节按「命令执行协议」操作：local 写脚本 → scp → ssh 执行 → commit。

### 机型

| 项目 | 值 |
|------|-----|
| 型号 | NUC / MacBook Pro / ThinkPad / 云服务器( ) / 其他______ |
| 制造商 | Intel / Apple / Dell / HP / 其他______ |

### CPU — lscpu / cat /proc/cpuinfo / nproc

```bash
# === local ===
cat > /tmp/kyb-{ts}-phy-cpu.sh << 'SCRIPT'
lscpu
cat /proc/cpuinfo | grep 'model name' | head -1
nproc
SCRIPT
# === local→remote ===
scp /tmp/kyb-{ts}-phy-cpu.sh {new-machine-ssh-user}@{new-machine-ssh-host}:~/.claude/audits/
ssh {new-machine-ssh-user}@{new-machine-ssh-host} bash ~/.claude/audits/kyb-{ts}-phy-cpu.sh
ssh {new-machine-ssh-user}@{new-machine-ssh-host} "cd ~/.claude && git add audits/ && git commit -m 'audit: cpu info'"
```

| 项目 | 值 |
|------|-----|
| 架构 | Intel / AMD / ARM (Apple Silicon) / 其他______ |
| 型号 | ______ |
| 核心数 | 2 / 4 / 8 / 16 / 32 |
| 频率 | ______ MHz |

### 内存 — free -h

```bash
# === local ===
cat > /tmp/kyb-{ts}-phy-mem.sh << 'SCRIPT'
free -h
SCRIPT
# === local→remote ===
scp /tmp/kyb-{ts}-phy-mem.sh {new-machine-ssh-user}@{new-machine-ssh-host}:~/.claude/audits/
ssh {new-machine-ssh-user}@{new-machine-ssh-host} bash ~/.claude/audits/kyb-{ts}-phy-mem.sh
ssh {new-machine-ssh-user}@{new-machine-ssh-host} "cd ~/.claude && git add audits/ && git commit -m 'audit: memory'"
```

| 项目 | 值 |
|------|-----|
| 总量 | 8G / 16G / 32G / 64G / 128G |
| 已用 | ______ |
| 空闲 | ______ |

### 磁盘 — lsblk / df -h

```bash
# === local ===
cat > /tmp/kyb-{ts}-phy-disk.sh << 'SCRIPT'
lsblk
df -h /
SCRIPT
# === local→remote === scp && ssh && commit
```

| 项目 | 值 |
|------|-----|
| 类型 | NVMe / SATA SSD / HDD / 云盘 |
| 总容量 | ______ |
| LVM / 分区 | 有 (root___ home___ 空闲___) / 无 / 不知道 |
| 根分区使用率 | ______ |

### 性能基准 — dd

```bash
# === local ===
cat > /tmp/kyb-{ts}-phy-dd.sh << 'SCRIPT'
dd if=/dev/zero of=/tmp/dd_test bs=1M count=1024 conv=fdatasync 2>&1 | tail -1
dd if=/tmp/dd_test of=/dev/null bs=1M 2>&1 | tail -1
rm -f /tmp/dd_test
SCRIPT
# === local→remote === scp && ssh && commit
```

| 测试 | 结果 |
|------|------|
| 顺序写 | ______ MB/s |
| 顺序读 | ______ MB/s |

### 确认

我确认以上硬件信息正确，过程已记录。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 探索日志

| # | 时间 (精确到秒) | 操作 | 结果 | 耗时 | commit |
|---|------|------|------|------|--------|
| 1 | | CPU 信息 | 成功/失败 | __s | |
| 2 | | 内存 | 成功/失败 | __s | |
| 3 | | 磁盘 | 成功/失败 | __s | |
| 4 | | dd 基准 | 成功/失败 | __s | |

## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)
