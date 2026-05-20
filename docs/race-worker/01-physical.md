# race-worker — 物理层

## CPU

- **架构**: aarch64 (ARM 64-bit)
- **厂商**: Apple
- **核心数**: 10 核 (10 CPU, 10 clusters)
- **频率**: 2.0 GHz (固定)
- **Thread(s) per core**: 1 (无超线程)
- **BogoMIPS**: 48.00
- **Flags**: fp asimd aes pmull sha1 sha2 crc32 atomics fphp asimdhp ...
- **安全漏洞**: 大部分 N/A (ARM 不受影响); Spec store bypass 标记为 Vulnerable

> 推测为 OrbStack 虚拟机运行的 Apple Silicon (M 系列) 硬件。

## 内存

| 项目 | 容量 |
|------|-------|
| 物理内存 (MemTotal) | 16 GiB (16,414,232 kB) |
| 可用 (MemAvailable) | ~10 GiB |
| Swap | 16 GiB (zram0: 15.7G + vdc: 1G) |
| Swap 已用 | ~2.4 GiB |

## 磁盘

| 设备 | 大小 | 类型 | 挂载点 | 文件系统 |
|------|------|------|--------|----------|
| vda | 364.3 MB | disk | — | — |
| vdb | 8 TB | disk | — | — |
| vdb1 | 926.4 GB | part | / (overlay) | btrfs |
| vdc | 1 GB | disk | [SWAP] | — |
| zram0 | 15.7 GB | disk | [SWAP] | — |

- **根文件系统**: overlay, 总 79 GiB, 已用 51 GiB (65%)
- **实际存储**: vdb 为 8TB 主磁盘, vdb1 分区 926.4G 挂载为 Docker overlay 存储
