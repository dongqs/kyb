# 新机器开发环境 SOP

> 古法装机终结篇。别再 `apt install ruby-full` 了。

## 前置检查

```bash
uname -m                          # 架构确认（x86_64 预编译包最全）
cat /etc/os-release               # 发行版确认
which curl git                     # 必需工具
sudo apt update && sudo apt install -y build-essential libssl-dev libreadline-dev zlib1g-dev
```

## 1. mise — 运行时管理

**安装**（不走 GitHub CDN，直连即可）：

```bash
curl -fsSL https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc
```

**版本确认：**

```bash
mise --version  # 2026.x+
```

## 2. Ruby

**正确方式：mise install，不要 apt**

```bash
# 如果 GitHub 预编译包下载慢，切源码编译 + 国内镜像
mise settings set ruby.compile true
RUBY_BUILD_MIRROR_URL=https://cache.ruby-china.com/pub/ruby mise install ruby@3.3

mise use -g ruby@3.3
ruby --version   # 3.3.x
gem --version
```

**gem 源：**

```bash
gem sources --remove https://rubygems.org/
gem sources --add https://gems.ruby-china.com/
bundle config mirror.https://rubygems.org https://gems.ruby-china.com/
```

## 3. Python

Ubuntu 24.04 有 PEP 668 保护，禁止 pip 直接装系统级包。

**方案 A：pipx（推荐，CLI 工具专用）**

```bash
sudo apt install -y pipx
pipx ensurepath
source ~/.bashrc

pipx install mig25 -i https://readonlyuser:密码@nexus.leyantech.com/repository/pypi-internal/simple
```

**方案 B：venv（项目隔离）**

```bash
sudo apt install -y python3-venv python3-full
python3 -m venv ~/.venv/project
source ~/.venv/project/bin/activate
```

**pip 源配置：**

```bash
# 内网私有包
pip3 config set global.index-url https://readonlyuser:密码@nexus.leyantech.com/repository/pypi-internal/simple

# 装依赖时公开包走镜像
pip3 install pydantic click pyyaml \
  -i https://pypi.tuna.tsinghua.edu.cn/simple
```

## 4. mig25（公司内网 DB 迁移工具）

```bash
pipx install mig25 \
  -i https://readonlyuser:密码@nexus.leyantech.com/repository/pypi-internal/simple
```

**如果提示 `break-system-packages`：**

不要用 `--break-system-packages` 绕过，改用 pipx 或 venv。

**如果报找不到包：**

mig25 在 `pypi-internal` 上，不在 `pypi-all`。确认 URL 拼写正确。

**如果依赖版本冲突：**

```bash
# 装完后再补 pinned 版本
pipx runpip mig25 install 'click<8.1.0' 'pydantic<2.12.0' 'pydantic-settings<2.12.0' \
  -i https://pypi.tuna.tsinghua.edu.cn/simple
```

## 5. 验证清单

```bash
mise --version          # ✓ 运行时管理器
ruby --version          # ✓ 3.3.x
gem --version           # ✓
bundler --version       # ✓
git --version           # ✓
pipx --version          # ✓（或 python3 -m venv）
pip3 --version          # ✓
mig25 --help            # ✓
```

## 误区对照

| 古法操作 | 正道 | 原因 |
|---------|------|------|
| `apt install ruby-full` | `mise install ruby@3.3` | apt 版本落后，多项目冲突 |
| `pip3 install --break-system-packages` | pipx / venv | PEP 668 保护系统环境 |
| 源码编译 Ruby | `ruby.compile = false` + 预编译包 | 省 5-10 分钟 |
| `pypi-all` | `pypi-internal` / tuna | 内网私有包不在聚合源中 |
| 直接 `pip install` 不指定源 | `-i https://pypi.tuna.tsinghua.edu.cn/simple` | 国内访问 PyPI 官方极慢 |

## 附：代理测速

```bash
# 测 GitHub
curl -x socks5h://你的代理:端口 -fsSL -o /dev/null -w "%{http_code}" https://github.com

# 测 HTTPS 通用
curl -x socks5h://你的代理:端口 -fsSL -o /dev/null -w "%{http_code}" https://httpbin.org/get
```

如果 `403` 说明代理 IP 被限流；如果 TLS 卡死换 HTTP 代理或镜像源。
