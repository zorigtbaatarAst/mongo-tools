#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$BASE_DIR/config.yml"

# ==============================
# ========== LOAD UI ===========
# ==============================
source "$BASE_DIR/ui.sh"

# ==============================
# ========== YAML FALLBACK =====
# ==============================
yaml_get() {
  local key="$1"
  awk -F': ' -v k="$key" '
    $1 == k {
      gsub(/"/, "", $2)
      print $2
    }
  ' "$CONFIG_FILE"
}

# ==============================
# ========== CONFIG LOAD =======
# ==============================
load_config() {
  ui_section "Loading configuration"

  if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -qi mikefarah; then
    ui_info "Using Go-based yq"

    DB_URI=$(yq '.mongo.uri' "$CONFIG_FILE")
    IMPORT_SEARCH_DIR=$(yq '.paths.import_search_dir' "$CONFIG_FILE" | envsubst)
    EXPORT_BASE_DIR=$(yq '.paths.export_base_dir' "$CONFIG_FILE" | envsubst)
    FZF_HEIGHT=$(yq '.ui.fzf_height' "$CONFIG_FILE")
    PREVIEW_LINES=$(yq '.ui.preview_lines' "$CONFIG_FILE")
  else
    ui_warn "yq not found or incompatible — using fallback parser"

    DB_URI=$(yaml_get uri)
    IMPORT_SEARCH_DIR=$(yaml_get import_search_dir)
    EXPORT_BASE_DIR=$(yaml_get export_base_dir)
    FZF_HEIGHT=$(yaml_get fzf_height)
    PREVIEW_LINES=$(yaml_get preview_lines)
  fi

  # ---- defaults ----
  DB_URI=${DB_URI:-"mongodb://localhost:27017"}
  IMPORT_SEARCH_DIR=${IMPORT_SEARCH_DIR:-"$HOME"}
  EXPORT_BASE_DIR=${EXPORT_BASE_DIR:-"$HOME/mongo-dumps"}
  FZF_HEIGHT=${FZF_HEIGHT:-"40%"}
  PREVIEW_LINES=${PREVIEW_LINES:-50}
}

# ---------- Helper ----------
strip_quotes() {
  # Remove any leading/trailing quotes from a string
  echo "$1" | sed 's/^"//; s/"$//'
}

safe_run() {
  # Run command with spinner, safe Ctrl+C
  local msg="$1"
  shift
  echo -ne "⏳ $msg..."
  
  "$@" &
  local pid=$!
  
  trap "kill $pid 2>/dev/null; exit" INT
  while kill -0 "$pid" 2>/dev/null; do
      printf "."
      sleep 0.2
  done
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

# ==============================
# ========== INIT ==============
# ==============================
ui_header
ui_require_cmd mongosh mongoimport mongodump fzf
load_config

ui_divider

OP=$(printf "import\nexport\n" | \
  fzf --prompt="Select operation > " --height 20% --border)

[[ -z "$OP" ]] && ui_error "Operation cancelled"

# ==============================
# ========== IMPORT ============
# ==============================
if [[ "$OP" == "import" ]]; then
  ui_header
  ui_section "Import JSON into MongoDB"

  JSON_FILE=$(find "$IMPORT_SEARCH_DIR" -type f -name '*.json' 2>/dev/null | \
    fzf --height "$FZF_HEIGHT" --border \
        --preview="head -n $PREVIEW_LINES {}")

  [[ -z "$JSON_FILE" ]] && ui_error "File selection cancelled"

  BASENAME=$(basename "$JSON_FILE" .json)
  DEFAULT_DB="${BASENAME%%.*}"
  DEFAULT_COLLECTION="${BASENAME#*.}"

  ui_section "Selecting database"

  TMP=$(mktemp)
  run_with_spinner "Fetching databases" \
    mongosh --quiet --eval \
    "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')" \
    > "$TMP"

  mapfile -t DBS < "$TMP"
  rm -f "$TMP"

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | fzf --query="$DEFAULT_DB")
  [[ -z "$DB_NAME" ]] && ui_error "Database required"

  ui_section "Selecting collection"

  mapfile -t COLS < <(
    mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')"
  )

  COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | \
    fzf --query="$DEFAULT_COLLECTION") || true

  COLLECTION_NAME=${COLLECTION_NAME:-$DEFAULT_COLLECTION}
  [[ -z "$COLLECTION_NAME" ]] && ui_error "Collection required"

  EXISTS=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION_NAME')")

  if [[ "$EXISTS" == "true" ]]; then
    ui_warn "Collection already exists"
    if ui_confirm "Drop existing collection?"; then
      run_with_spinner "Dropping collection" \
        mongosh --quiet --eval \
        "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').drop()"
    fi
  fi

  run_with_spinner "Importing documents" \
    mongoimport \
      --uri="$DB_URI" \
      --db "$DB_NAME" \
      --collection "$COLLECTION_NAME" \
      --file "$JSON_FILE" \
      --jsonArray

  COUNT=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').countDocuments()")

  ui_success "Imported $COUNT documents into $DB_NAME.$COLLECTION_NAME"
fi

# ================================
# ============ EXPORT ============
# ================================
if [[ "$OP" == "export" ]]; then
  ui_header

  # 1️⃣ Select database
  tmp=$(mktemp)
  run_with_spinner "Fetching databases..." \
    mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')" > "$tmp"
  mapfile -t DBS < "$tmp"
  rm -f "$tmp"

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | fzf --prompt="Database> " --height 30% --border)
  [[ -z "$DB_NAME" ]] && ui_error "Database required"

  # 2️⃣ Export scope
  SCOPE=$(printf "database\ncollection\n" | fzf --prompt="Export scope> " --height 10% --border)
  [[ -z "$SCOPE" ]] && ui_error "Scope required"

  COLLECTION_NAME=""
  if [[ "$SCOPE" == "collection" ]]; then
    tmp=$(mktemp)
    run_with_spinner "Fetching collections..." \
      mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')" > "$tmp"
    mapfile -t COLS < "$tmp"
    rm -f "$tmp"

    COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | fzf --prompt="Collection> " --height 30% --border)
    [[ -z "$COLLECTION_NAME" ]] && ui_error "Collection required"

    # 3️⃣ Show collection stats
  if [[ -n "$COLLECTION_NAME" ]]; then
    run_with_spinner "Fetching collection info..." \
      mongosh --quiet --eval "
        let s = db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').stats();
        print('Collection: ' + s.ns);
        print('Documents : ' + s.count);
        print('Avg doc size: ' + s.avgObjSize + ' bytes');
        print('Storage size: ' + s.storageSize + ' bytes');
        print('Total index size: ' + s.totalIndexSize + ' bytes');
    "
fi


  fi

  # 4️⃣ Choose format
  FORMAT=$(printf "bson\njson\ncsv\n" | fzf --prompt="Export format> " --height 10% --border)
  [[ -z "$FORMAT" ]] && ui_error "Format required"

  # 5️⃣ Ask if auto-zip
  read -rp "📦 Auto-zip export? [y/N]: " ZIP_CONFIRM
  ZIP_CONFIRM=${ZIP_CONFIRM,,}

  TS=$(date +%Y%m%d_%H%M%S)
  OUT_DIR="$EXPORT_BASE_DIR/dump-${DB_NAME}${COLLECTION_NAME:+-$COLLECTION_NAME}-$TS"
  mkdir -p "$OUT_DIR"

  # 6️⃣ Export commands
  if [[ "$FORMAT" == "bson" ]]; then
    ui_info "Exporting BSON (mongodump)..."
    run_with_spinner "Exporting..." \
      mongodump --uri="$DB_URI" --db "$DB_NAME" \
        ${COLLECTION_NAME:+--collection "$COLLECTION_NAME"} \
        --out "$OUT_DIR"

  elif [[ "$FORMAT" == "json" ]]; then
    ui_info "Exporting JSON..."
    if [[ -n "$COLLECTION_NAME" ]]; then
      run_with_spinner "Exporting JSON..." \
        mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').find().toArray()" > "$OUT_DIR/${COLLECTION_NAME}.json"
    else
      for col in $(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join(' ')"); do
        run_with_spinner "Exporting $col..." \
          mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$col').find().toArray()" > "$OUT_DIR/${col}.json"
      done
    fi

  elif [[ "$FORMAT" == "csv" ]]; then
    ui_info "Exporting CSV..."
    if [[ -z "$COLLECTION_NAME" ]]; then
      ui_error "CSV export only supports a single collection"
    fi

   # Safely fetch fields
  FIELDS=$(mongosh --quiet --eval \
    "JSON.stringify(db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').findOne())" \
    | jq -r 'keys | join(",")')

  read -rp "Fields to export (comma-separated) [$FIELDS]: " SELECTED_FIELDS
  SELECTED_FIELDS=${SELECTED_FIELDS:-$FIELDS}

  run_with_spinner "Exporting CSV..." \
    mongoexport --uri="$DB_URI" --db "$DB_NAME" --collection "$COLLECTION_NAME" \
      --type=csv --fields "$SELECTED_FIELDS" --out "$OUT_DIR/${COLLECTION_NAME}.csv"
fi

  # 7️⃣ Auto-zip if requested
  if [[ "$ZIP_CONFIRM" == "y" ]]; then
    ZIP_FILE="$EXPORT_BASE_DIR/dump-${DB_NAME}${COLLECTION_NAME:+-$COLLECTION_NAME}-$TS.zip"
    run_with_spinner "Zipping export..." \
      zip -r "$ZIP_FILE" "$OUT_DIR" >/dev/null
    ui_success "Exported and zipped to $ZIP_FILE"
  else
    ui_success "Exported to $OUT_DIR"
  fi
fi

