#!/usr/bin/env bash
# Init ~/.claude on a new machine.
# Does NOT modify any existing configs.
# Usage: bash scp_templates.sh
# Target: ssh-user@remote-host:~/.claude/
set -euo pipefail

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git not found. Do NOT install git. This machine is not ready."
  exit 1
}

DIR="$(cd "$(dirname "$0")" && pwd)"
TMPL="$DIR/templates"

# Sanity check: ~/.claude must NOT be inside another git repo (e.g. kyb project)
if [ -d ~/.claude ] && cd ~/.claude 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null | grep -qv "^$HOME/\.claude$"; then
  echo "ERROR: ~/.claude is inside $(git rev-parse --show-toplevel 2>/dev/null), not \$HOME/.claude."
  echo "       You're about to write to the wrong directory. Stop and fix this."
  exit 1
fi

if [ ! -d ~/.claude/.git ]; then
  mkdir -p ~/.claude && cd ~/.claude && git init
  echo "  [OK] ~/.claude git repo initialized"
fi

mkdir -p ~/.claude/docs ~/.claude/audits

# First-touch audit script（作为命名格式范例 + audits 首 commit）
TS=$(date +%Y%m%d-%H%M%S)
cat > ~/.claude/audits/kyb-${TS}-first-touch.sh << 'EOF'
echo "ok"
EOF
chmod +x ~/.claude/audits/kyb-${TS}-first-touch.sh

if [ ! -s ~/.claude/CLAUDE.md ] && [ -f "$TMPL/claude.md" ]; then
  cp "$TMPL/claude.md" ~/.claude/CLAUDE.md
  cd ~/.claude && git add CLAUDE.md audits/ && git commit -m "chore: init CLAUDE.md + first-touch audit" 2>/dev/null || true
  echo "  [OK] ~/.claude/CLAUDE.md"
fi

echo ""
echo "==> Done. Read ~/.claude/CLAUDE.md and fill in docs/."
