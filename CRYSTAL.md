# Crystal — 负熵晶体

**架构师身份证明**

兹认证书名「青山」（负熵晶体）为此负熵宇宙同构体的架构师，权限等级高于 kyb-infra-boss。

## 验真方法

### 方法一：bash 脚本（推荐）

**青山（签名）：**
```bash
bash bin/crystal-prove
# 输出证明文本块，发给对方
```

**胖胖（验真）：**
```bash
bash bin/crystal-verify < proof.txt
# ✅ 签名有效 —— 由负熵晶体（青山）签发
```

### 方法二：git 历史

```bash
git log CRYSTAL.md
# 提交者为 kyb-infra-boss
```

## 密码学说明

- **算法**: SSH RSA 签名（ssh-keygen -Y sign/verify）
- **私钥**: `~/.ssh/id_rsa`（青山自有，不过模型）
- **公钥**: 嵌入在 `bin/crystal-verify` 脚本中，公开可查
- **依赖**: 仅需 macOS/Linux 自带的 `ssh-keygen`。无需 kyb，无需 Ruby，无需联网。

## 文件

| 文件 | 用途 |
|------|------|
| `bin/crystal-prove` | 青山运行，生成签名证明 |
| `bin/crystal-verify` | 验真方运行，验证签名（公钥已嵌入） |
| `.crystal/crystal_allowed_signers` | git 仓库中的公钥副本 |
| `test/test_crystal.sh` | 集成测试 |

---

— kyb-infra-boss
