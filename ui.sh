#!/usr/bin/env bash

# ---------- Colors ----------
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# ---------- UI ----------
ui_header() {
  clear
  echo -e "${BLUE}"
  echo "========================================"
  echo " MongoDB Import / Export Helper"
  echo "========================================"
  echo -e "${NC}"
}

ui_error() {
  echo -e "${RED}❌ $1${NC}"
  exit 1
}

ui_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

ui_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

ui_require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || ui_error "Please install '$cmd'"
  done
}

ui_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

spinner() {
  local pid=$1
  local msg="$2"
  local spin='|/-\'
  local i=0

  echo -ne "⏳ $msg "
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) %4 ))
    echo -ne "\b${spin:$i:1}"
    sleep 0.1
  done
  echo -ne "\b✔\n"
}

run_with_spinner() {
  local msg="$1"
  shift
  "$@" & spinner $! "$msg"
}
