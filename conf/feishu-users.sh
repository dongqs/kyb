# Feishu user ID to display name mappings
# Source this file from scripts:
#   source "$(dirname "$0")/../conf/feishu-users.sh"
#
# Override by setting FEISHU_USER_MAP_FILE to a custom path, or by
# defining the FEISHU_USERS array before sourcing this file.

declare -A FEISHU_USERS
FEISHU_USERS=(
  ["ou_75b1fec6d3c2ae67ca1a65fea92a79f0"]="Aoyama"
)
