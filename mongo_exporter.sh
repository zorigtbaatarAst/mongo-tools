#!/usr/bin/env bash

# ========================================
# MongoDB JSON Export Helper
# ========================================

# Check for required commands
for cmd in mongosh mongoexport fzf; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Please install '$cmd' to proceed."
    exit 1
  fi
done

# MongoDB URI
DB_URI="mongodb://localhost:27017"

# ===== Step 1: Select Database =====
echo "Fetching database list..."
mapfile -t ALL_DBS < <(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')")
DB_NAME=$(printf "%s\n" "${ALL_DBS[@]}" | fzf --prompt="Database> " --height 30% --border)
if [ -z "$DB_NAME" ]; then
  echo "✋ Cancelled during database selection."
  exit 1
fi

# ===== Step 2: Choose export scope =====
read -rp "Do you want to export the whole DB or a single collection? [db/col] " SCOPE
SCOPE=${SCOPE,,} # lowercase

OUTPUT_DIR="./dumpfile"
mkdir -p "$OUTPUT_DIR"

if [[ "$SCOPE" == "col" ]]; then
  # Select collection
  echo "Fetching collections for DB '$DB_NAME'..."
  mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")
  COLLECTION_NAME=$(printf "%s\n" "${ALL_COLS[@]}" | fzf --prompt="Collection> " --height 30% --border)
  if [ -z "$COLLECTION_NAME" ]; then
    echo "✋ Cancelled during collection selection."
    exit 1
  fi

  # Export single collection to JSON
  OUT_FILE="${OUTPUT_DIR}/${DB_NAME}.${COLLECTION_NAME}.json"
  echo "⏳ Exporting $DB_NAME.$COLLECTION_NAME to $OUT_FILE..."
  mongoexport --uri="$DB_URI" --db="$DB_NAME" --collection="$COLLECTION_NAME" --out="$OUT_FILE" --jsonArray

else
  # Export all collections in DB
  echo "⏳ Exporting entire database '$DB_NAME'..."
  mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")
  for col in "${ALL_COLS[@]}"; do
    OUT_FILE="${OUTPUT_DIR}/${DB_NAME}.${col}.json"
    echo "⏳ Exporting collection '$col' to $OUT_FILE..."
    mongoexport --uri="$DB_URI" --db="$DB_NAME" --collection="$col" --out="$OUT_FILE" --jsonArray
  done
fi

# ===== Step 3: Done =====
echo "✅ Export complete!"
echo "   JSON files saved in directory: $OUTPUT_DIR"

