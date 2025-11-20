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

# -----------------------------------------------------------------------------
# 0. Stages setup
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
TOTAL_STAGES=10
CURRENT=0

# -----------------------------------------------------------------------------
# 1. Migration Start
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Migration Start"

# Record start time
START_TIME=$(date +%s)
echo "Migration started at: $(date '+%Y-%m-%d %H:%M:%S')"

# Parse ENV
[[ -f .env ]] && source .env || { echo "No .env file found"; exit 1; }
for var in OLD_USER OLD_IP NEW_USER NEW_IP MIGRATE_DIRS MIGRATE_FILES; do
  [[ -z "${!var:-}" ]] && { echo -e "\nERROR: $var is required in .env"; exit 1; }
done

# Parse Paths (directories/files)
[[ -z "${MIGRATE_DIRS//[, ]}" ]] && { echo -e "\nERROR: MIGRATE_DIRS cannot be empty"; exit 1; }
[[ -z "${MIGRATE_FILES//[, ]}" ]] && { echo -e "\nERROR: MIGRATE_FILES cannot be empty"; exit 1; }
IFS=',' read -ra RAW_DIRS <<< "$MIGRATE_DIRS"
IFS=',' read -ra RAW_FILES <<< "$MIGRATE_FILES"

declare -A dirs files

# get directories list
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

# get files list
for i in "${!RAW_FILES[@]}"; do
  src="${RAW_FILES[$i]#"${RAW_FILES[$i]%%[![:space:]]*}"}"
  src="${src%"${src##*[![:space:]]}"}"
  [[ -z "$src" ]] && continue
  [[ "$src" != /* ]] && { echo -e "\nERROR: File path must be absolute: $src"; exit 1; }
  files["$src"]=$(basename -- "$src")
done

# Validate directories and files exist
(( ${#dirs[@]} == 0 )) && { echo -e "\nERROR: No valid directories to migrate"; exit 1; }
(( ${#files[@]} == 0 && ${#dirs[@]} == 0 )) && { echo -e "\nERROR: Nothing to migrate"; exit 1; }

# Login paths
OLD_SERVER="${OLD_USER}@${OLD_IP}"
NEW_SERVER="${NEW_USER}@${NEW_IP}"

# Home directories
USER_HOME_OLD=$(ssh "$OLD_SERVER" "getent passwd \"$OLD_USER\" | cut -d: -f6")
USER_HOME_NEW=$(ssh "$NEW_SERVER" "getent passwd \"$NEW_USER\" | cut -d: -f6")

# -----------------------------------------------------------------------------
# 2. Data Collection (Old Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Data Backup (Old Server)"

# Defined directories
LOCAL_DIR="migration_data"
REMOTE_TMP="/tmp/migration"
BUNDLE="migration-bundle.tar.gz"
ssh "$OLD_SERVER" rm -rf "$REMOTE_TMP"
ssh "$OLD_SERVER" mkdir -p "$REMOTE_TMP/pm2"

# Directories backup
for src in "${!dirs[@]}"; do
  dest="${dirs[$src]}"
  if [[ "$src" = */ ]]; then
    ssh "$OLD_SERVER" rsync -aHAX --delete --numeric-ids "$src" "$REMOTE_TMP/$dest/"
  else
    ssh "$OLD_SERVER" rsync -aHAX --delete --numeric-ids "$src/" "$REMOTE_TMP/$dest/"
  fi
  echo "Backup done: $src"
done

# Files backup
for src in "${!files[@]}"; do
  dest="${files[$src]}"
  ssh "$OLD_SERVER" cp -a "$src" "$REMOTE_TMP/$dest"
  echo "Backup done: $src"
done

# PM2 saved
ssh "$OLD_SERVER" pm2 save
ssh "$OLD_SERVER" "cp -a \"$USER_HOME_OLD/.pm2/dump.pm2\" \
    \"$REMOTE_TMP/pm2/\" 2>/dev/null || true"

# NPM Backup
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

# -----------------------------------------------------------------------------
# 3. Data Compression (Old Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Data Compression (Old Server)"
SIZE_HUMAN=$(ssh "$OLD_SERVER" du -sh "$REMOTE_TMP" | cut -f1)
echo -e "Total data to compress: $SIZE_HUMAN"
echo -e "Compressing all data may take a while. Please wait..."
ssh "$OLD_SERVER" tar --numeric-owner -czf /tmp/"$BUNDLE" -C "$REMOTE_TMP" .
echo -e "\nCompression complete → /tmp/$BUNDLE ready"

# -----------------------------------------------------------------------------
# 4. Data Download (Old Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Data Download (Old Server)"
echo "Downloading data from old server..."
mkdir -p "$LOCAL_DIR"
if ! rsync -avh --progress "$OLD_SERVER:/tmp/$BUNDLE" "$LOCAL_DIR/$BUNDLE"; then
  echo -e "\nFirst attempt failed — retrying once..."
  sleep 3
  rsync -avh --progress "$OLD_SERVER:/tmp/$BUNDLE" "$LOCAL_DIR/$BUNDLE"
fi
echo -e "\nData saved → $LOCAL_DIR/$BUNDLE"

# -----------------------------------------------------------------------------
# 5. Data Upload (New Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Data Upload (New Server)"
if ! rsync -ah --info=progress2 \
           "$LOCAL_DIR/$BUNDLE" \
           "$NEW_SERVER:/tmp/$BUNDLE"; then
    echo 'Upload failed — retrying once...'
    sleep 5
    rsync -ah --info=progress2 \
          "$LOCAL_DIR/$BUNDLE" \
          "$NEW_SERVER:/tmp/$BUNDLE"
fi
echo 'Data upload completed'

# -----------------------------------------------------------------------------
# 6. Softwares Installation (New Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Softwares Installation (New Server)"

# Apache + jq
ssh "$NEW_SERVER" sudo apt update
ssh "$NEW_SERVER" sudo apt install -y apache2 jq curl

# Node.js
NODE_VERSION="${NODE_VERSION:-24}"
run_nvm() {
  ssh "$NEW_SERVER" "export LC_ALL=C NVM_DIR=\"$USER_HOME_NEW/.nvm\" && \
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && $*"
}
link_nvm_bin() {
  run_nvm "sudo ln -sf \"\$(nvm which current | xargs dirname)/$1\" /usr/bin/$1"
}
ssh "$NEW_SERVER" "export NVM_DIR=\"$USER_HOME_NEW/.nvm\" && [ -d \"\$NVM_DIR\" ] || \
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
run_nvm "nvm install $NODE_VERSION"
run_nvm "nvm alias default $NODE_VERSION"
run_nvm "nvm use $NODE_VERSION"
link_nvm_bin node
link_nvm_bin npm
link_nvm_bin npx

# -----------------------------------------------------------------------------
# 7. Restore Data (New Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Restore Data (New Server)"

# Prepare commands
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

# Extract directories and files into place
ssh "$NEW_SERVER" "rm -rf \"$REMOTE_TMP\" && mkdir -p \"$REMOTE_TMP\" \"$USER_HOME_NEW/.pm2\""
ssh "$NEW_SERVER" "tar -xzf /tmp/$BUNDLE -C \"$REMOTE_TMP\""
ssh "$NEW_SERVER" "bash -c '$RESTORE_CMDS'"

# -----------------------------------------------------------------------------
# 8. NPM Installation (New Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "NPM Installation (New Server)"
ssh "$NEW_SERVER" "sudo npm i -g pm2"
ssh "$NEW_SERVER" "jq -r '.dependencies | keys[]?' \
    \"$REMOTE_TMP/npm-global-packages.json\" | \
    xargs -r sudo npm i -g"
ssh "$NEW_SERVER" "jq -r '.dependencies | keys[]?' \
    \"$REMOTE_TMP/npm-root-packages.json\" | \
    xargs -r npm i --prefix /root"

# -----------------------------------------------------------------------------
# 9. Restore Processes (New Server)
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Restore Processes (New Server)"
ssh "$NEW_SERVER" "systemctl restart apache2 || true"
ssh "$NEW_SERVER" "mkdir -p \"$USER_HOME_NEW/.pm2\""
ssh "$NEW_SERVER" "cp -f \"$REMOTE_TMP/pm2/dump.pm2\" \"$USER_HOME_NEW/.pm2/dump.pm2\" 2>/dev/null || true"
ssh "$NEW_SERVER" "chown -R \"$NEW_USER:\" \"$USER_HOME_NEW/.pm2\""
ssh "$NEW_SERVER" "su - \"$NEW_USER\" -c 'pm2 resurrect || true'"
ssh "$NEW_SERVER" "su - \"$NEW_USER\" -c 'pm2 save'"

# -----------------------------------------------------------------------------
# 10. Finalising Migration
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Finalising Migration"

# Cleanup
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

# Final Summary
progress_bar $TOTAL_STAGES $TOTAL_STAGES "COMPLETE"
echo "MIGRATION COMPLETED SUCCESSFULLY!"
echo "Thank God 🤲"
echo "   • All paths migrated"
echo "   • Apache restarted"
echo "   • PM2 restored"
echo "   • Global packages reinstalled"
echo "   • Local backup: ./$LOCAL_DIR/"
echo "   • Total migration time: $TIME_TAKEN"
echo "   • Migration finished at: $(date '+%Y-%m-%d %H:%M:%S')"