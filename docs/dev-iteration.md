# kyb 自身开发迭代链路

kyb 自身开发请用 `--clone` 模式，确保宿主的 `~/.kyb/`（也是 build context）不受容器内修改影响。

## 正确步骤

```bash
# kyb 自身开发必须用 --clone 模式
kyb create --clone kyb fix-something

# 容器内验证改动
cd ~/projects/kyb
ruby -Ilib bin/kyb.rb preflight       # 用源码树验证
ruby -Itest test/test_docker.rb       # 跑测试

# Dockerfile/entrypoint 改了 → 需宿主编译
# 容器内改不到宿主的 build context
# 退出容器后在宿主线 kyb build
```

容器内 PATH 上的 `kyb` 是老版本。验证自身改动建议建 alias：

```bash
alias kyb-test='ruby -Ilib bin/kyb.rb'
```

## 文件布局

宿主的 `~/.kyb/` 既是 build context 也是源码目录。`--clone` 确保容器内有一个完全独立的副本，不干扰宿主的构建流程。

```
宿主 ~/.kyb/                     ← 源码 + build context（不受容器影响）
  Dockerfile
  entrypoint.sh
  lib/kyb/

~/.local/share/kyb/clones/kyb/
  kyb-kyb-fix-something/         ← --clone 的独立副本
    lib/kyb/                     ← 容器内 agent 随便改
```
