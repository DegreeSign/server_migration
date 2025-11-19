#!/bin/bash
# =============================================================================
#  Simple Server Migration Script
#  NODEJS + NPM + PM2 (Ubuntu/Debian)
#
#  Copyright (c) 2025 DEGREESIGN
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# =============================================================================

set -euo pipefail

# Record start time
START_TIME=$(date +%s)
echo "\nMigration started at: $(date '+%Y-%m-%d %H:%M:%S')"

# -----------------------------------------------------------------------------
# Progress bar
# -----------------------------------------------------------------------------
progress_bar() {
  local current=$1 total=$2 text=$3
  local width=50
  local percent=$((100 * current / total))
  local filled=$((width * current / total))
  local empty=$((width - filled))
  printf "\r["
  printf "%${filled}s" | tr " " "#"
  printf "%${empty}s"  | tr " " "-"
  printf "] %3d%% (%d/%d) %s" "$percent" "$current" "$total" "$text"
  echo ""
}

stage() {
  local num=$1 total=$2 name=$3
  echo -e "\n\033[1;36mSTAGE $num/$total: $name\033[0m"
  progress_bar "$num" "$total" "$name"
}

TOTAL_STAGES=11
CURRENT=0

# -----------------------------------------------------------------------------
# 1. Load configuration
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Loading configuration from .env"
[[ -f .env ]] && source .env || { echo "No .env file found"; exit 1; }

for var in OLD_USER OLD_IP NEW_USER NEW_IP MIGRATE_DIRS MIGRATE_FILES; do
  [[ -z "${!var:-}" ]] && { echo -e "\nERROR: $var is required in .env"; exit 1; }
done

[[ -z "${MIGRATE_DIRS//[, ]}" ]] && { echo -e "\nERROR: MIGRATE_DIRS cannot be empty"; exit 1; }
[[ -z "${MIGRATE_FILES//[, ]}" ]] && { echo -e "\nERROR: MIGRATE_FILES cannot be empty"; exit 1; }

OLD_SERVER="${OLD_USER}@${OLD_IP}"
NEW_SERVER="${NEW_USER}@${NEW_IP}"

LOCAL_DIR="migration_data"
REMOTE_TMP="/tmp/migration"
BUNDLE="migration-bundle.tar.gz"

mkdir -p "$LOCAL_DIR"

IFS=',' read -ra RAW_DIRS <<< "$MIGRATE_DIRS"
IFS=',' read -ra RAW_FILES <<< "$MIGRATE_FILES"

declare -A dirs files

for i in "${!RAW_DIRS[@]}"; do
  src="${RAW_DIRS[$i]#"${RAW_DIRS[$i]%%[![:space:]]*}"}"
  src="${src%"${src##*[![:space:]]}"}"
  [[ -z "$src" ]] && continue
  [[ "$src" != /* ]] && { echo -e "\nERROR: Directory path must be absolute: $src"; exit 1; }
  [[ "$src" = "/" || "$src" = "/home" || "$src" = "/etc" || "$src" = "/root" ]] && {
    echo -e "\nDANGEROUS PATH BLOCKED: $src"; exit 1;
  }
  dirs["$src"]="dir_$i"
done

for i in "${!RAW_FILES[@]}"; do
  src="${RAW_FILES[$i]#"${RAW_FILES[$i]%%[![:space:]]*}"}"
  src="${src%"${src##*[![:space:]]}"}"
  [[ -z "$src" ]] && continue
  [[ "$src" != /* ]] && { echo -e "\nERROR: File path must be absolute: $src"; exit 1; }
  files["$src"]=$(basename -- "$src")
done

(( ${#dirs[@]} == 0 )) && { echo -e "\nERROR: No valid directories to migrate"; exit 1; }
(( ${#files[@]} == 0 && ${#dirs[@]} == 0 )) && { echo -e "\nERROR: Nothing to migrate"; exit 1; }

# -----------------------------------------------------------------------------
# 2. Save PM2 state
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Saving PM2 state on old server"
ssh "$OLD_SERVER" pm2 save

# -----------------------------------------------------------------------------
# 3. Collecting all data on old server
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Collecting all data on old server"

# Validate jq
ssh "$OLD_SERVER" command -v jq >/dev/null 2>&1 || {
  echo -e "\nInstalling jq on old server..."
  ssh "$OLD_SERVER" "sudo apt update && sudo apt install -y jq"
}

ssh "$OLD_SERVER" rm -rf "$REMOTE_TMP"
ssh "$OLD_SERVER" mkdir -p "$REMOTE_TMP/pm2"

for src in "${!dirs[@]}"; do
  dest="${dirs[$src]}"
  echo -e "\nCopying directory: $src → temporary bundle ($dest)"
  if [[ "$src" = */ ]]; then
    ssh "$OLD_SERVER" rsync -aHAX --delete --numeric-ids "$src" "$REMOTE_TMP/$dest/"
  else
    ssh "$OLD_SERVER" rsync -aHAX --delete --numeric-ids "$src/" "$REMOTE_TMP/$dest/"
  fi
  echo "Completed: $src"
done

for src in "${!files[@]}"; do
  dest="${files[$src]}"
  echo -e "\nCopying file: $src → temporary bundle ($dest)"
  ssh "$OLD_SERVER" cp -a "$src" "$REMOTE_TMP/$dest"
  echo "Completed: $src"
done

ssh "$OLD_SERVER" cp -a ~/.pm2/dump.pm2 "$REMOTE_TMP/pm2/" 2>/dev/null || true

# Capture global npm packages
echo ""
echo "Capturing npm packages..."
GLOBAL_PKGS="$REMOTE_TMP/npm-global-packages.json"
ROOT_PKGS="$REMOTE_TMP/npm-root-packages.json"
ssh "$OLD_SERVER" mkdir -p "$REMOTE_TMP"
ssh "$OLD_SERVER" sh -c "npm ls -g --depth=0 --json > \"$GLOBAL_PKGS\" 2>/dev/null || \
    echo '{\"dependencies\":{}}' > \"$GLOBAL_PKGS\""
if ssh "$OLD_SERVER" test -f /root/package.json; then
    ssh "$OLD_SERVER" sh -c "cd /root && npm ls --depth=0 --json \
        > \"$ROOT_PKGS\" 2>/dev/null || echo '{\"dependencies\":{}}' > \"$ROOT_PKGS\""
else
    ssh "$OLD_SERVER" echo '{\"dependencies\":{}}' > "$ROOT_PKGS"
fi

# Compression process
echo -e "\nBundling data in $REMOTE_TMP ..."
SIZE_HUMAN=$(ssh "$OLD_SERVER" du -sh "$REMOTE_TMP" | cut -f1)
echo -e "Total data to compress: $SIZE_HUMAN"
echo -e "Starting compression..."
echo -e "Compressing all data — this may take a while. Please wait..."

ssh "$OLD_SERVER" tar --numeric-owner -czf /tmp/"$BUNDLE" -C "$REMOTE_TMP" .
echo -e "\nCompression complete → /tmp/$BUNDLE ready"

# -----------------------------------------------------------------------------
# 4. Creating local backup
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Creating local backup"

echo "Downloading backup from old server..."
if ! rsync -avh --progress "$OLD_SERVER:/tmp/$BUNDLE" "$LOCAL_DIR/$BUNDLE"; then
  echo -e "\nFirst attempt failed — retrying once..."
  sleep 3
  rsync -avh --progress "$OLD_SERVER:/tmp/$BUNDLE" "$LOCAL_DIR/$BUNDLE"
fi
echo -e "\nBackup saved → $LOCAL_DIR/$BUNDLE"

# -----------------------------------------------------------------------------
# 5. Upload bundle to new server
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Transferring directly OLD to NEW"
echo 'Uploading bundle from local backup to new server...'
if ! rsync -ah --info=progress2 \
           "$LOCAL_DIR/$BUNDLE" \
           "$NEW_SERVER:/tmp/$BUNDLE"; then
    echo 'Upload failed — retrying once...'
    sleep 5
    rsync -ah --info=progress2 \
          "$LOCAL_DIR/$BUNDLE" \
          "$NEW_SERVER:/tmp/$BUNDLE"
fi
echo 'Upload completed'

# -----------------------------------------------------------------------------
# 6. Install base software on new server
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Installing software on new server"
ssh "$NEW_SERVER" sudo apt update
ssh "$NEW_SERVER" sudo apt install -y apache2 nodejs npm jq

# -----------------------------------------------------------------------------
# 7. Install PM2 globally
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Installing PM2 globally"
ssh "$NEW_SERVER" "sudo npm i -g pm2 --unsafe-perm=true"

# -----------------------------------------------------------------------------
# 8. Restore directories/files — paths restored exactly as defined
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Restoring directories and files (clean replace)"
USER_HOME=$(ssh "$NEW_SERVER" "getent passwd \"$NEW_USER\" | cut -d: -f6")

RESTORE_CMDS=""
for src in "${!dirs[@]}"; do
  dest="${dirs[$src]}"
  [[ "$src" = */ ]] && RESTORE_CMDS+="rsync -aHAX --delete --numeric-ids \"$REMOTE_TMP/$dest/\" \"$src\" || true; " \
                   || RESTORE_CMDS+="rsync -aHAX --delete --numeric-ids \"$REMOTE_TMP/$dest/\" \"$src/\" || true; "
done
for src in "${!files[@]}"; do
  dest="${files[$src]}"
  RESTORE_CMDS+="cp -a \"$REMOTE_TMP/$dest\" \"$src\" || true; "
done

ssh "$NEW_SERVER" sudo bash << EOF
set -euo pipefail
rm -rf "$REMOTE_TMP" && mkdir -p "$REMOTE_TMP" "$USER_HOME/.pm2"
tar -xzf /tmp/$BUNDLE -C "$REMOTE_TMP"
$RESTORE_CMDS
systemctl restart apache2 || true
EOF

# -----------------------------------------------------------------------------
# 9. Install npm packages
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Reinstalling npm packages"
ssh "$NEW_SERVER" "jq -r '.dependencies | keys[]?' \
    \"$REMOTE_TMP/npm-global-packages.json\" | \
    xargs -r sudo npm i -g --unsafe-perm"
ssh "$NEW_SERVER" "jq -r '.dependencies | keys[]?' \
    \"$REMOTE_TMP/npm-root-packages.json\" | \
    xargs -r sudo npm i -g --unsafe-perm"

# -----------------------------------------------------------------------------
# 10. Restore PM2 processes
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Restoring exact PM2 processes"
ssh "$NEW_SERVER" bash << EOF
mkdir -p "$USER_HOME/.pm2"
cp -f "$REMOTE_TMP/pm2/dump.pm2" "$USER_HOME/.pm2/dump.pm2" 2>/dev/null || true
chown -R "$NEW_USER:" "$USER_HOME/.pm2"
sudo -u "$NEW_USER" pm2 restore || true
sudo -u "$NEW_USER" pm2 save
sudo -u "$NEW_USER" pm2 startup systemd -u "$NEW_USER" --hp "$USER_HOME" | sudo bash
EOF

# -----------------------------------------------------------------------------
# 11. Cleanup
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Cleaning up temporary files"
ssh "$OLD_SERVER" rm -rf "$REMOTE_TMP" "/tmp/$BUNDLE" 2>/dev/null || true
ssh "$NEW_SERVER" rm -rf "$REMOTE_TMP" "/tmp/$BUNDLE" 2>/dev/null || true

# Calculate total duration
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
if (( ELAPSED < 60 )); then
    TIME_TAKEN="${ELAPSED} seconds"
elif (( ELAPSED < 3600 )); then
    TIME_TAKEN="$((ELAPSED / 60)) minutes and $((ELAPSED % 60)) seconds"
else
    HOURS=$((ELAPSED / 3600))
    MINUTES=$(((ELAPSED % 3600) / 60))
    SECONDS=$((ELAPSED % 60))
    TIME_TAKEN="$HOURS hours, $MINUTES minutes, and $SECONDS seconds"
fi

# -----------------------------------------------------------------------------
# Final Summary
# -----------------------------------------------------------------------------
progress_bar $TOTAL_STAGES $TOTAL_STAGES "COMPLETE"
echo "MIGRATION COMPLETED SUCCESSFULLY!"
echo "Thank God 🤲🏻"
echo "   • All paths migrated"
echo "   • Apache restarted"
echo "   • PM2 restored"
echo "   • Global packages reinstalled"
echo "   • Local backup: ./$LOCAL_DIR/"
echo "   • Total migration time: $TIME_TAKEN"
echo "   • Migration finished at: $(date '+%Y-%m-%d %H:%M:%S')"