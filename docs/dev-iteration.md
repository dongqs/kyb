# kyb 自身开发迭代链路

kyb 开发中修改代码后验证流程容易踩坑，主要是因为源码和 build context 存在两个不同路径。

## 文件布局

```
宿主机 macOS
├── ~/github/kyb/              ← 路径 A：kyb build 的 build context
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── lib/kyb/
│
├── ~/projects/                 ← 路径 B：容器挂载的代码目录
│   └── kyb/                    ← 实际编辑位置
│       ├── Dockerfile
│       ├── entrypoint.sh
│       └── lib/kyb/
│
└── ~/.config/kyb/config.yml    ← 配置指向路径 A
    base.image: /Users/dongqs/github/kyb
```

## 两条链路

```
修改 lib/kyb/*.rb
  ├── 测试         → ruby -Itest test/                    ✅ 源码树直接跑
  ├── CLI 验证     → ruby -Ilib bin/kyb                   ✅ 源码树直接跑
  ├── kyb 命令验证 → cp lib/* ~/.kyb/lib/ && kyb         ⚠️ 需同步到 ~/.kyb/
  └── 完整镜像验证 → 需要 commit 后 build                  ❌ 路径 A vs B

修改 entrypoint.sh / Dockerfile
  └── 完整镜像验证 → kyb build                            ❌ build context 是路径 A
```

## 关键陷阱

### 1. kyb build 不认当前编辑的文件

`kyb build` 从 `config.yml` 的 `base.image` 读 build context，通常是宿主机路径
`~/github/kyb`（路径 A）。容器内编辑的是挂载的 `~/projects/kyb`（路径 B）。

**两边可能是不同 commit、不同分支。**

### 2. kyb 命令不认源码树

`kyb` 在 PATH 里指向 `~/.kyb/bin/kyb`（镜像构建时 COPY 进去的），不是
`~/projects/kyb/bin/kyb`。改 `lib/` 后直接跑 `kyb` 不会生效。

### 3. 验证特定改动的正确步骤

```bash
# 1) Ruby 逻辑改动：同步到 ~/.kyb/ 或从源码树跑
cp ~/projects/kyb/lib/kyb/cli/did.rb ~/.kyb/lib/kyb/cli/did.rb

# 2) entrypoint/Dockerfile 改动：同步到 build context 再 build
cp ~/projects/kyb/entrypoint.sh /Users/dongqs/github/kyb/entrypoint.sh
kyb build

# 3) 创建测试容器
KYB_BRANCH=test ruby -Ilib bin/kyb did create test-name

# 4) 清理
ruby -Ilib bin/kyb did rm test-name
```

## 根因

`config.yml` 的 `base.image` 和容器内挂载的代码目录是**两个独立的 git clone**，
build context 路径没有统一。修法是让 `base.image` 指向容器内也能访问的统一路径，
或确保 build context 与编辑位置一致。
