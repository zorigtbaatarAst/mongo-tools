#!/usr/bin/env bash
set -euo pipefail

# ==============================
# ========== COLORS ============
# ==============================
RESET="\033[0m"

BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
GRAY="\033[90m"

# ==============================
# ========== ICONS ============
# ==============================
ICON_INFO="ℹ️ "
ICON_WARN="⚠️ "
ICON_ERROR="❌ "
ICON_OK="✅ "
ICON_RUN="⏳ "
ICON_SECTION="▶"
ICON_HEADER="🛢️"

# ==============================
# ========== BASIC UI ==========
# ==============================
ui_header() {
  clear
  echo -e "${BOLD}${CYAN}${ICON_HEADER} Mongo Helper${RESET}"
  echo -e "${GRAY}────────────────────────────────────────────${RESET}"
}

ui_section() {
  echo
  echo -e "${BOLD}${BLUE}${ICON_SECTION} $*${RESET}"
}

ui_info() {
  echo -e "${CYAN}${ICON_INFO}$*${RESET}"
}

ui_warn() {
  echo -e "${YELLOW}${ICON_WARN}$*${RESET}"
}

ui_error() {
  echo -e "${RED}${ICON_ERROR}$*${RESET}"
  exit 1
}

ui_success() {
  echo -e "${GREEN}${ICON_OK}$*${RESET}"
}

# ==============================
# ========== DEP CHECK =========
# ==============================
ui_require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    ui_error "Missing required commands: ${missing[*]}"
  fi
}

# ==============================
# ========== SPINNER ===========
# ==============================
run_with_spinner() {
  local msg="$1"
  shift
  local cmd=("$@")
  
  echo -ne "⏳ $msg..."
  
  # Run command in foreground (so Ctrl+C works)
  "${cmd[@]}" &
  local pid=$!
  
  # Trap Ctrl+C to kill child
  trap "kill $pid 2>/dev/null; exit" INT
  
  # Wait for command
  wait $pid
  local status=$?
  
  trap - INT
  if [[ $status -eq 0 ]]; then
    echo -e " ✅ Done"
  else
    echo -e " ❌ Failed"
    return $status
  fi
}


spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
      local temp=${spinstr#?}
      printf " [%c]  " "$spinstr"
      spinstr=$temp${spinstr%"$temp"}
      sleep $delay
      printf "\b\b\b\b\b\b"
  done
}

# ==============================
# ========== CONFIRM ===========
# ==============================
ui_confirm() {
  local prompt="${1:-Are you sure?}"
  read -rp "$(echo -e "${YELLOW}? ${prompt} [y/N]: ${RESET}")" ans
  [[ "${ans,,}" == "y" ]]
}

# ==============================
# ========== DIVIDER ===========
# ==============================
ui_divider() {
  echo -e "${GRAY}────────────────────────────────────────────${RESET}"
}

