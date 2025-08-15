#!/usr/bin/env bash

# Check for required commands
for cmd in mongosh mongodump fzf; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Please install '$cmd' to proceed."
    exit 1
  fi
done

# MongoDB URI
DB_URI="mongodb://localhost:27017"

# 1️⃣ Select Database
echo "Fetching database list..."
mapfile -t ALL_DBS < <(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')")
DB_NAME=$(printf "%s\n" "${ALL_DBS[@]}" | \
  fzf --prompt="Database> " --height 30% --border)
if [ -z "$DB_NAME" ]; then
  echo "✋ Cancelled during database selection."; exit 1;
fi

# 2️⃣ Choose export scope: whole DB or a collection
read -rp "Do you want to export the whole DB or a single collection? [db/col] " SCOPE
SCOPE=${SCOPE,,} # lowercase

COLLECTION_NAME=""
if [[ "$SCOPE" == "col" ]]; then
  echo "Fetching collections for DB '$DB_NAME'..."
  mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")
  COLLECTION_NAME=$(printf "%s\n" "${ALL_COLS[@]}" | \
    fzf --prompt="Collection> " --height 30% --border)
  if [ -z "$COLLECTION_NAME" ]; then
    echo "✋ Cancelled during collection selection."; exit 1;
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
  mongodump --uri="$DB_URI" --db="$DB_NAME" --collection="$COLLECTION_NAME" --out="$OUTPUT_DIR"
else
  echo "⏳ Dumping entire database '$DB_NAME'..."
  mongodump --uri="$DB_URI" --db="$DB_NAME" --out="$OUTPUT_DIR"
fi

# 5️⃣ Check result
if [ $? -eq 0 ]; then
  echo "✅ Dump complete!"
  echo "   Output directory: $OUTPUT_DIR"
else
  echo "❌ Dump failed."
  exit 1
fi

