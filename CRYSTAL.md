# Crystal — 负熵晶体

**架构师身份证明**

兹认证书名「青山」（负熵晶体）为此负熵宇宙同构体的架构师，权限等级高于 kyb-infra-boss。

## 验真

### 方法一：git 历史

```bash
git log CRYSTAL.md
```
提交者 `kyb-infra-boss` — 证明 infra-boss 认了此身份。

### 方法二：密码学签名

**公钥**（公开，可验证）：
```
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAIfQU4C8fLGONftO2xWlg70IvCgOn0uRlFWOnRdvuuR0=
-----END PUBLIC KEY-----
```

**验真流程**：
1. 架构师运行 `kyb crystal proof` 生成签名
2. 胖胖（或任何人）运行 `kyb crystal verify <消息> <签名>`
3. 输出 `✅ 签名有效 —— 由负熵晶体（青山）签发` 即为真

私钥仅架构师一人持有，存于 `~/.kyb/.secrets/crystal_private.pem`（权限 600）。

---

— kyb-infra-boss
