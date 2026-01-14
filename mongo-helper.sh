#!/usr/bin/env bash
set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Load UI ----------
source "$BASE_DIR/ui.sh"

# ---------- Load YAML Config ----------
CONFIG_FILE="$BASE_DIR/config.yml"

# ---------- Config Loader ----------
load_config() {
  if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -qi mikefarah; then
    ui_info "Using yq (Go-based)"

    DB_URI=$(yq '.mongo.uri' "$CONFIG_FILE")
    IMPORT_SEARCH_DIR=$(yq '.paths.import_search_dir' "$CONFIG_FILE" | envsubst)
    EXPORT_BASE_DIR=$(yq '.paths.export_base_dir' "$CONFIG_FILE" | envsubst)
    FZF_HEIGHT=$(yq '.ui.fzf_height' "$CONFIG_FILE")
    PREVIEW_LINES=$(yq '.ui.preview_lines' "$CONFIG_FILE")
  else
    ui_warn "yq not found or wrong version — using fallback YAML parser"

    DB_URI=$(yaml_get uri)
    IMPORT_SEARCH_DIR=$(yaml_get import_search_dir)
    EXPORT_BASE_DIR=$(yaml_get export_base_dir)
    FZF_HEIGHT=$(yaml_get fzf_height)
    PREVIEW_LINES=$(yaml_get preview_lines)
  fi

  # ---------- Defaults safety ----------
  DB_URI=${DB_URI:-"mongodb://localhost:27017"}
  IMPORT_SEARCH_DIR=${IMPORT_SEARCH_DIR:-"$HOME"}
  EXPORT_BASE_DIR=${EXPORT_BASE_DIR:-"$HOME/mongo-dumps"}
  FZF_HEIGHT=${FZF_HEIGHT:-"40%"}
  PREVIEW_LINES=${PREVIEW_LINES:-50}
}

load_config

DB_URI=$(yq '.mongo.uri' "$CONFIG_FILE")
IMPORT_SEARCH_DIR=$(yq '.paths.import_search_dir' "$CONFIG_FILE" | envsubst)
EXPORT_BASE_DIR=$(yq '.paths.export_base_dir' "$CONFIG_FILE" | envsubst)
FZF_HEIGHT=$(yq '.ui.fzf_height' "$CONFIG_FILE")
PREVIEW_LINES=$(yq '.ui.preview_lines' "$CONFIG_FILE")

# ---------- Dependencies ----------
ui_require_cmd mongosh mongoimport mongodump fzf

ui_header

OP=$(printf "import\nexport\n" | fzf --prompt="Select operation> " --height 20% --border)
[[ -z "$OP" ]] && ui_error "Operation cancelled"


yaml_get() {
  local key="$1"
  awk -F': ' -v k="$key" '
    $1 == k {
      gsub(/"/, "", $2)
      print $2
    }
  ' "$CONFIG_FILE"
}

# ================================
# ============ IMPORT ============
# ================================
if [[ "$OP" == "import" ]]; then
  ui_header
  echo "📂 Select JSON file"

  JSON_FILE=$(find "$IMPORT_SEARCH_DIR" -type f -name '*.json' 2>/dev/null | \
    fzf --height "$FZF_HEIGHT" --border \
        --preview="head -n $PREVIEW_LINES {}")

  [[ -z "$JSON_FILE" ]] && ui_error "File selection cancelled"

  BASENAME=$(basename "$JSON_FILE" .json)
  [[ "$BASENAME" == *.* ]] \
    && DEFAULT_DB="${BASENAME%%.*}" \
    || DEFAULT_DB=""

  DEFAULT_COLLECTION="${BASENAME#*.}"

  ui_header

tmp=$(mktemp)
run_with_spinner "Fetching databases" \
  mongosh --quiet --eval \
  "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')" \
  > "$tmp"

mapfile -t DBS < "$tmp"
rm -f "$tmp"

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | fzf --query="$DEFAULT_DB")
  [[ -z "$DB_NAME" ]] && ui_error "Database required"

  mapfile -t COLS < <(
    mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')"
  )

  COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | fzf --query="$DEFAULT_COLLECTION") || true
  COLLECTION_NAME=${COLLECTION_NAME:-$DEFAULT_COLLECTION}
  [[ -z "$COLLECTION_NAME" ]] && ui_error "Collection required"

  EXISTS=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION_NAME')")

  if [[ "$EXISTS" == "true" ]]; then
    read -rp "Drop collection? [y/N]: " DROP
    [[ "${DROP,,}" == "y" ]] && \
      mongosh --quiet --eval \
      "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').drop()"
  fi

  run_with_spinner "Importing documents into $DB_NAME.$COLLECTION_NAME" \
  mongoimport \
    --uri="$DB_URI" \
    --db "$DB_NAME" \
    --collection "$COLLECTION_NAME" \
    --file "$JSON_FILE" \
    --jsonArray

  COUNT=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').countDocuments()")

  ui_success "Imported $COUNT documents"
fi

# ================================
# ============ EXPORT ============
# ================================
if [[ "$OP" == "export" ]]; then
  ui_header
  mapfile -t DBS < <(
    mongosh --quiet --eval \
    "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')"
  )

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | fzf)
  [[ -z "$DB_NAME" ]] && ui_error "Database required"

  SCOPE=$(printf "database\ncollection\n" | fzf)
  [[ -z "$SCOPE" ]] && ui_error "Scope required"

  COLLECTION_NAME=""
  if [[ "$SCOPE" == "collection" ]]; then
    mapfile -t COLS < <(
      mongosh --quiet --eval \
      "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')"
    )
    COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | fzf)
  fi

  TS=$(date +%Y%m%d_%H%M%S)
  OUT="$EXPORT_BASE_DIR/dump-${DB_NAME}${COLLECTION_NAME:+-$COLLECTION_NAME}-$TS"
  mkdir -p "$OUT"

run_with_spinner "Exporting MongoDB data" \
  mongodump --uri="$DB_URI" --db "$DB_NAME" \
    ${COLLECTION_NAME:+--collection "$COLLECTION_NAME"} \
    --out "$OUT"

  ui_success "Exported to $OUT"
fi

