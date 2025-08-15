#!/usr/bin/env bash

# Check for required commands
for cmd in mongosh mongoimport fzf; do
  if ! command -v $cmd &> /dev/null; then
    echo "❌ Please install '$cmd' to proceed."
    exit 1
  fi
done

# 1️⃣ Interactive JSON file picker first
echo "Select JSON file to import (searching in $HOME):"
JSON_FILE=$(find "$HOME" -type f -name '*.json' 2>/dev/null | \
  fzf --prompt="File> " --height 50% --border \
      --preview='head -n 50 {}'
)
if [ -z "$JSON_FILE" ]; then
  echo "✋ Cancelled during file selection."; exit 1;
fi
if [ ! -f "$JSON_FILE" ]; then
  echo "❌ File not found: $JSON_FILE"; exit 1;
fi

# Derive basename without extension
iBASENAME=$(basename "$JSON_FILE" .json)

# Default DB and collection from dot-separated basename
if [[ "$iBASENAME" == *.* ]]; then
  DEFAULT_DB="${iBASENAME%%.*}"
  DEFAULT_COLLECTION="${iBASENAME#*.}"
else
  DEFAULT_DB=""
  DEFAULT_COLLECTION="$iBASENAME"
fi

# 2️⃣ Select Database with fzf, initial query = default
echo "Fetching database list..."
mapfile -t ALL_DBS < <(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join('\n')")
DB_NAME=$(printf "%s\n" "${ALL_DBS[@]}" | \
  fzf --prompt="Database> " --height 30% --border --query="$DEFAULT_DB")
if [ -z "$DB_NAME" ]; then
  echo "✋ Cancelled during database selection."; exit 1;
fi


# 3️⃣ Select or enter Collection with fzf, fallback to manual input
echo "Fetching collection list for DB '$DB_NAME'..."
mapfile -t ALL_COLS < <(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().join('\n')")

COLLECTION_NAME=$(printf "%s\n" "${ALL_COLS[@]}" | \
  fzf --prompt="Collection> " --height 30% --border --query="$DEFAULT_COLLECTION" --header="[Enter: select, Ctrl-C: cancel, Ctrl-E: manual input]")

# If fzf was cancelled, fallback to manual input with default value
if [ $? -ne 0 ] || [ -z "$COLLECTION_NAME" ]; then
  echo "✋ No collection selected. Enter collection name manually:"
  read -rp "Collection Name [$DEFAULT_COLLECTION]: " input_collection
  # Use default if empty input
  COLLECTION_NAME=${input_collection:-$DEFAULT_COLLECTION}

  if [ -z "$COLLECTION_NAME" ]; then
    echo "❌ Collection name cannot be empty."; exit 1;
  fi

  echo "👉 Using collection: $COLLECTION_NAME"
fi


# 4️⃣ Check if collection exists, ask to drop if yes
echo "⏳ Checking if collection '$COLLECTION_NAME' exists in '$DB_NAME'..."
COL_EXISTS=$(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION_NAME')")

if [[ "$COL_EXISTS" == "true" ]]; then
  echo "⚠️ Collection '$COLLECTION_NAME' already exists in DB '$DB_NAME'."
  read -rp "❓ Do you want to drop the existing collection before import? [y/N]: " DROP_CONFIRM
  DROP_CONFIRM=${DROP_CONFIRM,,}  # to lowercase
  if [[ "$DROP_CONFIRM" == "y" || "$DROP_CONFIRM" == "yes" ]]; then
    echo "🔥 Dropping existing collection '$COLLECTION_NAME'..."
    mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').drop()"
    echo "✅ Collection dropped."
  else
    echo "🚫 Keeping existing collection. New documents will be added."
  fi
fi

echo "✅ Final DB: $DB_NAME, Collection: $COLLECTION_NAME"


# 4️⃣ Import data
echo "⏳ Importing into $DB_NAME.$COLLECTION_NAME..."
mongoimport --uri="mongodb://localhost:27017" \
  --db "$DB_NAME" \
  --collection "$COLLECTION_NAME" \
  --file "$JSON_FILE" \
  --jsonArray

# 5️⃣ Report result
if [ $? -eq 0 ]; then
  COUNT=$(mongosh --quiet --eval "db.getSiblingDB('$DB_NAME').getCollection('$COLLECTION_NAME').countDocuments()")
  echo "✅ Import complete!"
  echo "   File: $JSON_FILE"
  echo "   DB: $DB_NAME"
  echo "   Collection: $COLLECTION_NAME"
  echo "   Documents now: $COUNT"
else
  echo "❌ Import failed."; exit 1;
fi

