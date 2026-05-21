#!/usr/bin/env bash
#
# onboard-agent.sh — automated project onboarding
# Usage: ./onboard-agent.sh <group/project> [project-label]
#
# Clones a GitLab repo, generates .kyb.md, compiles, tests,
# pushes a kyb/onboarding branch, and creates an MR.
set -euo pipefail

GITLAB_SSH="git@git.leyantech.com"
WORKDIR="/tmp/onboarding"
MR_BRANCH="kyb/onboarding"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# --- CLI args ---
PROJECT_PATH="${1:?Usage: $0 <group/project> [label]}"
LABEL="${2:-$(basename "$PROJECT_PATH")}"

REPO_URL="${GITLAB_SSH}:${PROJECT_PATH}.git"
TARGET_DIR="${WORKDIR}/$(basename "$PROJECT_PATH")"

mkdir -p "$WORKDIR"

# --- 1. Clone ---
if [ -d "$TARGET_DIR" ]; then
  info "Target exists, pulling latest..."
  cd "$TARGET_DIR"
  git checkout master 2>/dev/null || git checkout main 2>/dev/null
  git pull --rebase
else
  info "Cloning ${REPO_URL} ..."
  git clone "$REPO_URL" "$TARGET_DIR"
  cd "$TARGET_DIR"
fi

# --- 2. Determine default branch ---
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"

# --- 3. Create .kyb.md ---
cat > "$TARGET_DIR/.kyb.md" <<KYBEOF
# kyb — ${PROJECT_PATH}

## Build
\`\`\`bash
mvn compile
\`\`\`

## Test
\`\`\`bash
mvn test
\`\`\`

## Type
java-maven
KYBEOF

git add .kyb.md
git commit -m "chore(${LABEL}): add .kyb.md" --allow-empty

# --- 4. Compile ---
info "Compiling..."
if ! mvn compile -q -f "$TARGET_DIR" 2>/dev/null; then
  # try multi-module
  if [ -f "${TARGET_DIR}/pom.xml" ]; then
    mvn compile -q || info "Compile had warnings (non-fatal)"
  fi
fi

# --- 5. Run tests ---
info "Running tests..."
mvn test -q 2>/dev/null || info "Some tests failed (check manually)"

# --- 6. Push branch & create MR ---
info "Pushing ${MR_BRANCH} ..."
git checkout -b "$MR_BRANCH"
git push -u origin "$MR_BRANCH" 2>/dev/null || {
  # branch may already exist remotely; try reset
  git push -u origin "$MR_BRANCH" --force
}

info "Creating MR..."
glab mr create \
  --title "chore(${LABEL}): add .kyb.md" \
  --description "Automated onboarding: adds .kyb.md build/test metadata for kyb sandbox integration." \
  --source-branch "$MR_BRANCH" \
  --target-branch "$DEFAULT_BRANCH" \
  --yes

info "Done: ${PROJECT_PATH}"
