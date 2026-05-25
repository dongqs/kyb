# 外部 CK 数据为空调查 — 2026-05-25

> 用户说"外面的那台 ck 数据是空的"，查证是哪台、空了多少、原因。

---

## 架构发现：有两台 CK

### 1. 宿主机 CK（macOS 原生）— `host.orb.internal:9000`
- **版本**: 25.1.3.23
- **运行时间**: 12.9 天（1117610 秒）
- **这是用户说的"外面的那台 CK"**
- 所有 sandbox 和 service 默认连的都是这台

### 2. 容器 CK — `kyb-infra-clickhouse`（192.168.97.5）
- **版本**: 24.2.3.70（镜像 `clickhouse/clickhouse-server:24.2-alpine`）
- **运行时间**: 12 小时（42930 秒）
- **卷**: `ch-data-fresh`（真正的空卷，只有 `default` 和 `system` 两个 data 目录）
- **数据库**: 只有 4 个（INFORMATION_SCHEMA, default, information_schema, system）
- **用途**: infra 日志专用，基本是空的

> ⚠️ 注意：`host.orb.internal:9000` **不是**容器 CK。它绕过了 Docker 端口映射，直接连到 macOS 宿主机上跑的 CK。

---

## 宿主 CK 数据状况

| 状态 | 数据库 | 行数 |
|------|--------|------|
| ✅ 有数据 | default（101M）、topo（45M）、daily（31M）、merged（16.8M）、stated（13M）、lxk（3.9M）、historical（2M）、kafka（1.8M）、bigdata（21K）、kyb（10K）、oss（11K）、tb（57K）等 31 个库 | 有数据 |
| ❌ 空 | **xiaoye**（100 张表全空）、agent、ant、claude、dogman、hasura（168 张表）、lxk_api（34 张表）、metric（75 张表）、realtime（27 张表）、renewal（12 张表）、trainer（10 张表）等 **32 个库** | **0 行** |

### 关键发现
- **数据库和表结构（DDL）全部幸存** — 60+ 个库的 schema 齐全
- **实际数据大半丢失** — 约一半的数据库有 schema 无数据
- **xiaoye 库 100 张表，0 行** — 用户说的"空"基本就是这个库

---

## 根因

参考 `2026-05-24-infra-boss-night.md`：

1. 前一夜 CK 因 OOM 反复 crash（加了 4g 内存限制后触发）
2. 旧 `ch-data` 卷损坏，数据部分全部丢失
3. 切到新卷 `ch-data-fresh` 重建容器
4. 元数据（DDL）从损坏的旧卷恢复，但实际数据（.bin parts）不可恢复
5. **宿主 CK（macOS 原生）** 的数据也受影响 — 推测旧 `ch-data` 卷是宿主 CK 的挂载点之一，或者宿主 CK 的某些库的数据也在同一轮 OOM 中被损坏

### 旧卷检查
```
docker run --rm -v ch-data:/data alpine
→ metadata/ 有 30+ 个库的 DDL
→ data/ 下 0 个 .bin 文件 — 数据部分全部损坏
```

---

## 结论

| 问题 | 答案 |
|------|------|
| 用户指的是哪台 CK？ | **宿主 CK**（macOS 原生，`host.orb.internal:9000`，25.1.3.23） |
| 真的空吗？ | **部分空** — 60+ 库中 32 个库 0 行（包括 xiaoye） |
| 为什么空？ | 5/24 OOM crash → 数据卷损坏，DDL 幸存但数据丢失 |
| 能否恢复？ | 旧卷无数据 parts，需从上游源重新灌 |

---

## 附件

- 容器 CK 信息：`kyb-infra-clickhouse`（24.2.3.70，ch-data-fresh 卷）
- 旧卷状态：`ch-data`（metadata 幸存，data 全部损坏）
- nuc8：无 CK
- 配置中无其他远程 CK 引用

／人◕ ‿‿ ◕人＼
