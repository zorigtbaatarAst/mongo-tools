#!/usr/bin/env bash

# ========================================
# MongoDB Interactive Import & Export Helper
# UI + Config Version
# ========================================

set -e

# ---------- Load Config ----------
CONFIG_FILE="$HOME/.mongo-helper.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "⚠️  Config file not found: $CONFIG_FILE"
  echo "👉 Using built-in defaults"
fi

# ---------- Defaults ----------
DB_URI=${DB_URI:-"mongodb://localhost:27017"}
IMPORT_SEARCH_DIR=${IMPORT_SEARCH_DIR:-"$HOME"}
EXPORT_BASE_DIR=${EXPORT_BASE_DIR:-"./"}
FZF_HEIGHT=${FZF_HEIGHT:-"40%"}
PREVIEW_LINES=${PREVIEW_LINES:-50}

# ---------- UI Helpers ----------
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

header() {
  clear
  echo -e "${BLUE}"
  echo "========================================"
  echo " MongoDB Import / Export Helper"
  echo "========================================"
  echo -e "${NC}"
}

error() {
  echo -e "${RED}❌ $1${NC}"
  exit 1
}

success() {
  echo -e "${GREEN}✅ $1${NC}"
}

warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

# ---------- Check Dependencies ----------
for cmd in mongosh mongoimport mongodump fzf; do
  command -v "$cmd" &>/dev/null || error "Please install '$cmd'"
done

header

# ---------- Operation Selection ----------
OP=$(printf "import\nexport\n" | \
  fzf --prompt="Select operation> " --height 20% --border)

[[ -z "$OP" ]] && error "Operation cancelled"

# ================================
# ============ IMPORT ============
# ================================
if [[ "$OP" == "import" ]]; then
  header
  echo "📂 Select JSON file to import"

  JSON_FILE=$(find "$IMPORT_SEARCH_DIR" -type f -name '*.json' 2>/dev/null | \
    fzf --prompt="File> " \
        --height "$FZF_HEIGHT" \
        --border \
        --preview="head -n $PREVIEW_LINES {}")

  [[ -z "$JSON_FILE" ]] && error "File selection cancelled"

  BASENAME=$(basename "$JSON_FILE" .json)
  if [[ "$BASENAME" == *.* ]]; then
    DEFAULT_DB="${BASENAME%%.*}"
    DEFAULT_COLLECTION="${BASENAME#*.}"
  else
    DEFAULT_DB=""
    DEFAULT_COLLECTION="$BASENAME"
  fi

  header
  echo "🗄️  Select database"

  mapfile -t DBS < <(
    mongosh --quiet --eval \
    "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')"
  )

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | \
    fzf --query="$DEFAULT_DB" --prompt="Database> " --height 30% --border)

  [[ -z "$DB_NAME" ]] && error "Database selection cancelled"

  header
  echo "📑 Select collection"

  mapfile -t COLS < <(
    mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')"
  )

  COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | \
    fzf --query="$DEFAULT_COLLECTION" \
        --prompt="Collection (Enter=new)> " \
        --height 30% --border) || true

  if [[ -z "$COLLECTION_NAME" ]]; then
    read -rp "Collection name [$DEFAULT_COLLECTION]: " COLLECTION_NAME
    COLLECTION_NAME=${COLLECTION_NAME:-$DEFAULT_COLLECTION}
  fi

  [[ -z "$COLLECTION_NAME" ]] && error "Collection name required"

  EXISTS=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION_NAME')")

  if [[ "$EXISTS" == "true" ]]; then
    read -rp "Drop existing collection? [y/N]: " DROP
    if [[ "${DROP,,}" == "y" ]]; then
      mongosh --quiet --eval \
        "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').drop()"
      success "Collection dropped"
    else
      warn "Appending to existing collection"
    fi
  fi

  header
  echo "⏳ Importing data..."
  mongoimport \
    --uri="$DB_URI" \
    --db "$DB_NAME" \
    --collection "$COLLECTION_NAME" \
    --file "$JSON_FILE" \
    --jsonArray

  COUNT=$(mongosh --quiet --eval \
    "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').countDocuments()")

  success "Import complete"
  echo "📄 File       : $JSON_FILE"
  echo "🗄️  Database   : $DB_NAME"
  echo "📑 Collection : $COLLECTION_NAME"
  echo "🔢 Documents  : $COUNT"
fi

# ================================
# ============ EXPORT ============
# ================================
if [[ "$OP" == "export" ]]; then
  header
  echo "🗄️  Select database"

  mapfile -t DBS < <(
    mongosh --quiet --eval \
    "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')"
  )

  DB_NAME=$(printf "%s\n" "${DBS[@]}" | \
    fzf --prompt="Database> " --height 30% --border)

  [[ -z "$DB_NAME" ]] && error "Database selection cancelled"

  SCOPE=$(printf "database\ncollection\n" | \
    fzf --prompt="Export scope> " --height 20% --border)

  [[ -z "$SCOPE" ]] && error "Scope selection cancelled"

  COLLECTION_NAME=""
  if [[ "$SCOPE" == "collection" ]]; then
    mapfile -t COLS < <(
      mongosh --quiet --eval \
      "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')"
    )

    COLLECTION_NAME=$(printf "%s\n" "${COLS[@]}" | \
      fzf --prompt="Collection> " --height 30% --border)

    [[ -z "$COLLECTION_NAME" ]] && error "Collection selection cancelled"
  fi

  TS=$(date +%Y%m%d_%H%M%S)
  OUT="$EXPORT_BASE_DIR/dump-${DB_NAME}${COLLECTION_NAME:+-$COLLECTION_NAME}-$TS"
  mkdir -p "$OUT"

  header
  echo "⏳ Exporting..."

  if [[ -n "$COLLECTION_NAME" ]]; then
    mongodump --uri="$DB_URI" \
      --db "$DB_NAME" \
      --collection "$COLLECTION_NAME" \
      --out "$OUT"
  else
    mongodump --uri="$DB_URI" \
      --db "$DB_NAME" \
      --out "$OUT"
  fi

  success "Export complete"
  echo "📁 Output: $OUT"
fi

