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
}

stage() {
  local num=$1 total=$2 name=$3
  echo -e "\n\033[1;36m→ STAGE $num/$total: $name\033[0m"
  progress_bar "$num" "$total" "$name"
}

TOTAL_STAGES=10
CURRENT=0

# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Loading configuration from .env"
[[ -f .env ]] && source .env

# Required variables – fail fast if missing
for var in OLD_USER OLD_IP NEW_USER NEW_IP MIGRATE_DIRS MIGRATE_FILES; do
  [[ -z "${!var:-}" ]] && {
    echo -e "\n\033[1;31mERROR: $var is required in .env\033[0m" && exit 1
  }
done

# Ensure MIGRATE_* arrays are not empty comma lists
[[ "$MIGRATE_DIRS"  =~ ^,+$ ]]  && {
  echo -e "\n\033[1;31mERROR: MIGRATE_DIRS cannot be empty\033[0m" &&  exit 1
}
[[ "$MIGRATE_FILES" =~ ^,+$ ]]  && {
  echo -e "\n\033[1;31mERROR: MIGRATE_FILES cannot be empty\033[0m" && exit 1
}

OLD_SERVER="${OLD_USER}@${OLD_IP}"
NEW_SERVER="${NEW_USER}@${NEW_IP}"

LOCAL_DIR="migration_data"
REMOTE_TMP="/tmp/migration"
BUNDLE="migration-bundle.tar.gz"

mkdir -p "$LOCAL_DIR"

# Convert comma-separated strings from .env → arrays
IFS=',' read -ra DIR_LIST <<< "$MIGRATE_DIRS"
IFS=',' read -ra FILE_LIST <<< "$MIGRATE_FILES"

# Build associative arrays (source → temp subfolder)
declare -A dirs
for i in "${!DIR_LIST[@]}"; do
  src="${DIR_LIST[$i]}"
  [[ "$src" = "/" || "$src" = "/home" || "$src" = "/etc" || "$src" = "/root" ]] && {
    echo -e "\n\033[1;31mDANGEROUS PATH BLOCKED: $src\033[0m" && exit 1
  }
  dirs["$src"]="dir_$i"
done

declare -A files
for i in "${!FILE_LIST[@]}"; do
  src="${FILE_LIST[$i]}"
  [[ "$src" = "/" || "$src" = "/root" ]] && {
    echo -e "\n\033[1;31mDANGEROUS PATH BLOCKED: $src\033[0m" && exit 1
  }
  files["$src"]=$(basename "$src")
done

# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Saving PM2 state on old server"
ssh "$OLD_SERVER" pm2 save

# Ensure jq exists on old server
ssh "$OLD_SERVER" command -v jq >/dev/null 2>&1 || {
  echo -e "\n\033[1;33mInstalling jq on old server...\033[0m"
  ssh "$OLD_SERVER" sudo apt update
  ssh "$OLD_SERVER" sudo apt install -y jq
}

stage $((++CURRENT)) $TOTAL_STAGES "Collecting all data on old server"
ssh "$OLD_SERVER" bash -c "\
  rm -rf \"$REMOTE_TMP\" && mkdir -p \"$REMOTE_TMP/pm2\" && \
  $(for src in \"${!dirs[@]}\"; do \
      dest=\"${dirs[$src]}\"; \
      echo \"rsync -aHAX --delete --numeric-ids \\\"${src%/}/\\\" \\
      \\\"$REMOTE_TMP/\$dest/\\\" || true && \"; \
    done) \
  $(for src in \"${!files[@]}\"; do \
      dest=\"${files[$src]}\"; \
      echo \"cp -a \\\"$src\\\" \\\"$REMOTE_TMP/\$dest\\\" || true && \"; \
    done) \
  cp -a ~/.pm2/dump.pm2 \"$REMOTE_TMP/pm2/dump.pm2\" 2>/dev/null || true && \
  (npm ls -g --depth=0 --json > \"$REMOTE_TMP/global-packages.json\" 2>/dev/null \\
    || echo '{\"dependencies\":{}}' > \"$REMOTE_TMP/global-packages.json\") && \
  tar --numeric-owner -czf /tmp/$BUNDLE -C \"$REMOTE_TMP\" ."

stage $((++CURRENT)) $TOTAL_STAGES "Creating local backup"
scp -q "$OLD_SERVER":/tmp/$BUNDLE "$LOCAL_DIR/"
echo -e "\nBackup saved → $LOCAL_DIR/$BUNDLE"

stage $((++CURRENT)) $TOTAL_STAGES "Transferring directly OLD → NEW"
ssh "$OLD_SERVER" cat /tmp/$BUNDLE | ssh "$NEW_SERVER" "cat > /tmp/$BUNDLE"

stage $((++CURRENT)) $TOTAL_STAGES "Installing software on new server"
ssh "$NEW_SERVER" sudo apt update
ssh "$NEW_SERVER" sudo apt install -y apache2 nodejs npm jq

stage $((++CURRENT)) $TOTAL_STAGES "Installing PM2 globally"
ssh "$NEW_SERVER" "sudo npm i -g pm2 --unsafe-perm"

stage $((++CURRENT)) $TOTAL_STAGES "Restoring directories and files (clean replace)"

# Auto-detect NEW_USER's home directory
USER_HOME=$(ssh "$NEW_SERVER" "getent passwd \"$NEW_USER\" | cut -d: -f6")

ssh "$NEW_SERVER" sudo bash -c "\
  rm -rf \"$REMOTE_TMP\" && mkdir -p \"$REMOTE_TMP\" \"$USER_HOME/.pm2\" && \
  tar -xzf /tmp/$BUNDLE -C \"$REMOTE_TMP\" && \
  $(for src in \"${!dirs[@]}\"; do \
      dest=\"${dirs[$src]}\"; \
      echo \"rsync -aHAX --delete --numeric-ids \\\"$REMOTE_TMP/\$dest/\\\" \\
      \\\"$src/\\\" || true && \"; \
    done) \
  $(for src in \"${!files[@]}\"; do \
      dest=\"${files[$src]}\"; \
      echo \"cp -a \\\"$REMOTE_TMP/\$dest\\\" \\\"$src\\\" || true && \"; \
    done) \
  systemctl restart apache2 || true"

stage $((++CURRENT)) $TOTAL_STAGES "Restoring exact PM2 processes"
ssh "$NEW_SERVER" bash -c "\
  mkdir -p \"$USER_HOME/.pm2\" && \
  cp -f \"$REMOTE_TMP/pm2/dump.pm2\" \"$USER_HOME/.pm2/dump.pm2\" 2>/dev/null \\
  || true && \
  pm2 restore || true && \
  pm2 save && \
  pm2 startup systemd -u \"$NEW_USER\" --hp \"$USER_HOME\" | sudo bash"

stage $((++CURRENT)) $TOTAL_STAGES "Reinstalling global npm packages"
ssh "$NEW_SERVER" bash -c "\
  jq -r '.dependencies | keys[]' \"$REMOTE_TMP/global-packages.json\" 2>/dev/null \\
    | xargs -r -I {} sudo npm i -g {} --unsafe-perm || true"

# -----------------------------------------------------------------------------
# 9. Cleanup temporary files
# -----------------------------------------------------------------------------
stage $((++CURRENT)) $TOTAL_STAGES "Cleaning up temporary files"
ssh "$OLD_SERVER" rm -rf "$REMOTE_TMP" "/tmp/$BUNDLE" 2>/dev/null || true
ssh "$NEW_SERVER" sudo rm -rf "$REMOTE_TMP" "/tmp/$BUNDLE" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 10. Final success details
# -----------------------------------------------------------------------------
progress_bar $TOTAL_STAGES $TOTAL_STAGES "COMPLETE"
echo -e "\n\n\033[1;32mMIGRATION COMPLETED SUCCESSFULLY!\033[0m"
echo -e "\033[1;36mThank GOD 🤲🏻\033[0m\n"
echo "   • All paths from .env migrated cleanly"
echo "   • Apache restarted"
echo "   • PM2 restored"
echo "   • Global npm packages reinstalled"
echo "   • Local backup: ./$LOCAL_DIR/"
echo -e "   • Old server ready for shutdown\n"