#!/usr/bin/env bash

# ========================================
# MongoDB Interactive Import & Export Helper
# ========================================

# Check for required commands
for cmd in mongosh mongoimport mongodump fzf; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Please install '$cmd' to proceed."
    exit 1
  fi
done

# MongoDB URI
DB_URI="mongodb://localhost:27017"

# ===== Step 1: Choose operation =====
read -rp "Select operation [import/export]: " OP
OP=${OP,,}  # lowercase

if [[ "$OP" != "import" && "$OP" != "export" ]]; then
  echo "❌ Invalid operation. Use 'import' or 'export'."
  exit 1
fi

# ================================
# ======== IMPORT LOGIC ==========
# ================================
if [[ "$OP" == "import" ]]; then

  # 1️⃣ Interactive JSON file picker
  echo "Select JSON file to import (searching in $HOME):"
  JSON_FILE=$(find "$HOME" -type f -name '*.json' 2>/dev/null | \
    fzf --prompt="File> " --height 50% --border \
        --preview='head -n 50 {}'
  )
  if [ -z "$JSON_FILE" ]; then
    echo "✋ Cancelled during file selection."; exit 1
  fi
  if [ ! -f "$JSON_FILE" ]; then
    echo "❌ File not found: $JSON_FILE"; exit 1
  fi

  # Derive basename without extension
  iBASENAME=$(basename "$JSON_FILE" .json)
  if [[ "$iBASENAME" == *.* ]]; then
    DEFAULT_DB="${iBASENAME%%.*}"
    DEFAULT_COLLECTION="${iBASENAME#*.}"
  else
    DEFAULT_DB=""
    DEFAULT_COLLECTION="$iBASENAME"
  fi

  # 2️⃣ Select Database
  echo "Fetching database list..."
  mapfile -t ALL_DBS < <(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')")
  DB_NAME=$(printf "%s\n" "${ALL_DBS[@]}" | \
    fzf --prompt="Database> " --height 30% --border --query="$DEFAULT_DB")
  if [ -z "$DB_NAME" ]; then
    echo "✋ Cancelled during database selection."; exit 1
  fi

  # 3️⃣ Select Collection
  echo "Fetching collection list for DB '$DB_NAME'..."
  mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")
  COLLECTION_NAME=$(printf "%s\n" "${ALL_COLS[@]}" | \
    fzf --prompt="Collection> " --height 30% --border --query="$DEFAULT_COLLECTION" --header="[Enter: select, Ctrl-C: cancel, Ctrl-E: manual input]")

  if [ $? -ne 0 ] || [ -z "$COLLECTION_NAME" ]; then
    read -rp "Collection Name [$DEFAULT_COLLECTION]: " input_collection
    COLLECTION_NAME=${input_collection:-$DEFAULT_COLLECTION}
    if [ -z "$COLLECTION_NAME" ]; then
      echo "❌ Collection name cannot be empty."; exit 1
    fi
    echo "👉 Using collection: $COLLECTION_NAME"
  fi

  # 4️⃣ Check if collection exists, ask to drop if yes
  COL_EXISTS=$(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION_NAME')")
  if [[ "$COL_EXISTS" == "true" ]]; then
    read -rp "⚠️ Collection '$COLLECTION_NAME' exists. Drop it? [y/N]: " DROP_CONFIRM
    DROP_CONFIRM=${DROP_CONFIRM,,}
    if [[ "$DROP_CONFIRM" == "y" || "$DROP_CONFIRM" == "yes" ]]; then
      echo "🔥 Dropping collection..."
      mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').drop()"
      echo "✅ Collection dropped."
    else
      echo "🚫 Keeping existing collection. New documents will be added."
    fi
  fi

  # 5️⃣ Import data
  echo "⏳ Importing '$JSON_FILE' into $DB_NAME.$COLLECTION_NAME..."
  mongoimport --uri="$DB_URI" --db "$DB_NAME" --collection "$COLLECTION_NAME" --file "$JSON_FILE" --jsonArray

  if [ $? -eq 0 ]; then
    COUNT=$(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').countDocuments()")
    echo "✅ Import complete!"
    echo "   File: $JSON_FILE"
    echo "   DB: $DB_NAME"
    echo "   Collection: $COLLECTION_NAME"
    echo "   Documents now: $COUNT"
  else
    echo "❌ Import failed."; exit 1
  fi
fi

# ================================
# ======== EXPORT LOGIC ==========
# ================================
if [[ "$OP" == "export" ]]; then

  # 1️⃣ Select Database
  echo "Fetching database list..."
  mapfile -t ALL_DBS < <(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')")
  DB_NAME=$(printf "%s\n" "${ALL_DBS[@]}" | \
    fzf --prompt="Database> " --height 30% --border)
  if [ -z "$DB_NAME" ]; then
    echo "✋ Cancelled during database selection."; exit 1
  fi

  # 2️⃣ Choose scope: DB or collection
  read -rp "Export whole DB or a single collection? [db/col] " SCOPE
  SCOPE=${SCOPE,,}

  COLLECTION_NAME=""
  if [[ "$SCOPE" == "col" ]]; then
    echo "Fetching collections for DB '$DB_NAME'..."
    mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")
    COLLECTION_NAME=$(printf "%s\n" "${ALL_COLS[@]}" | fzf --prompt="Collection> " --height 30% --border)
    if [ -z "$COLLECTION_NAME" ]; then
      echo "✋ Cancelled during collection selection."; exit 1
    fi
  fi

  # 3️⃣ Output directory
  TS=$(date +%Y%m%d_%H%M%S)
  if [ -n "$COLLECTION_NAME" ]; then
    OUTPUT_DIR="./dump-${DB_NAME}-${COLLECTION_NAME}-${TS}"
  else
    OUTPUT_DIR="./dump-${DB_NAME}-${TS}"
  fi
  mkdir -p "$OUTPUT_DIR"

  # 4️⃣ Run mongodump
  if [ -n "$COLLECTION_NAME" ]; then
    echo "⏳ Dumping collection '$DB_NAME.$COLLECTION_NAME'..."
    mongodump --uri="$DB_URI" --db "$DB_NAME" --collection "$COLLECTION_NAME" --out "$OUTPUT_DIR"
  else
    echo "⏳ Dumping entire database '$DB_NAME'..."
    mongodump --uri="$DB_URI" --db "$DB_NAME" --out "$OUTPUT_DIR"
  fi

  # 5️⃣ Check result
  if [ $? -eq 0 ]; then
    echo "✅ Dump complete!"
    echo "   Output directory: $OUTPUT_DIR"
  else
    echo "❌ Dump failed."; exit 1
  fi
fi

