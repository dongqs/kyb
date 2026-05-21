# SSH in kyb Containers

## 关键约束：`~/.ssh` 是只读挂载

kyb 容器内 `~/.ssh` 来自宿主机只读挂载（见 `README.md`），**不能写入**。

这意味着：

| 不能做的事 | 原因 |
|-----------|------|
| `ssh-keyscan host >> ~/.ssh/known_hosts` | 文件只读 |
| `ssh-keygen` 生成新密钥 | 目录只读 |
| 修改 `~/.ssh/config` | 文件只读 |

## 影响

每次创建新容器，known_hosts 都是宿主机那份快照。如果连的是动态 host key 的机器，就会卡在 host key 校验。

### 典型场景：kyb 容器 host key 漂移

kyb 容器 hostname = container ID，每次 `kyb create` 重建容器 hostname 和 host key 都变。如果 SSH 到另一个 kyb 容器，每次都会遇到 host key 冲突。

解法：方案 A（`StrictHostKeyChecking no`）或方案 C（ControlMaster 复用连接）。

## 解法

### 方案 A：宿主机 SSH config 加 `StrictHostKeyChecking no`

在宿主机 `~/.ssh/config` 对应 Host 块加一行：

```
Host nuc8
  HostName 100.98.29.39
  User dongqs
  StrictHostKeyChecking no
```

容器里直接继承，免校验。

### 方案 B：宿主机加 known_hosts

```
ssh-keyscan <host> >> ~/.ssh/known_hosts
```

适合 host key 固定的机器，容器里直接认。

### 方案 C：宿主机起 SSH 复用连接

```
Host nuc8
  ControlMaster auto
  ControlPath /tmp/ssh-mux-%r@%h:%p
  ControlPersist 10m
```

宿主机连过一次后，10 分钟内容器里复用同一连接，跳过校验。

## 为什么这么设计

`~/.ssh` 只读是为了安全——不把 SSH 密钥泄露到可能不信任的容器环境。修改配置统一在宿主机上做。

## 教训

> 要在容器里 SSH，相关配置**必须提前在宿主机配好**。容器里发现 known_hosts 不对，你是改不了的。
