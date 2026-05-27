# 2026-05-27 — Crystal 负熵晶体系统

原始文件：`CRYSTAL.md` + `.crystal/`(8 文件) + `.secrets/`(3 文件)

**Crystal = 架构师身份证明系统。** 用 SSH RSA 签名（ssh-keygen -Y sign/verify）做离线验真。私钥在 `~/.ssh/id_rsa`（不过模型），公钥公开。

验证流程：`crystal-prove` 生成签名证明 → 对方 `crystal-verify` 验真。依赖仅 macOS/Linux 自带的 ssh-keygen，无需 kyb、Ruby、联网。

内容包括：kyb-superiority-proof（优越性证明签名）、pangpang-delegation（胖胖委任书）。

架构师身份已通过 diary 中的负熵晶体系列文档传承。密码学材料（crystal scripts 脚本、测试）已在此前清理中删除。密钥材料、证明文件、委任书为历史快照。

压缩后删除 `CRYSTAL.md`、`.crystal/`、`.secrets/`。
