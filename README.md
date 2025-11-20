# DegreeSign | Apache + PM2 Server Migration

One-command migration for Ubuntu servers running Apache + PM2 + Node.js apps

Migrates everything safely and exactly:
- Apache config
- Web files
- SSL certificates
- PM2 apps (original paths preserved via `dump.pm2`)
- Global npm packages
- 10 automated steps

License: Apache-2.0 [LICENSE](LICENSE)

## Project Setup
### Directory Setup

```bash
# Install migration package
yarn add @degreesign/migrate

# Create migration folder
mkdir -p tmp_migration

# Copy example env config
cp node_modules/@degreesign/migrate/.env.example ./tmp_migration/.env

# Open tmp_migration
cd tmp_migration
```

### Configuration Setup
Edit [.env](.env.example) with your server details and paths
IMPORTANT:
* FOLLOWING DETAILS ARE JUST PLACEHOLDERS
* REVIEW AND UPDATE REQUIRED BEFORE USE

```env
# Node.js
NODE_VERSION=24

# SSH details
OLD_USER='old_username'
OLD_IP='0.0.0.0'
NEW_USER='new_username'
NEW_IP='1.1.1.1'

# Comma-separated – no spaces after commas
MIGRATE_DIRS='/root/pm2_files,/var/www,/etc/letsencrypt'
MIGRATE_FILES='/etc/apache2/apache2.conf,/etc/ssh/sshd_config'
```
## Run
Run the migration

```bash
npx @degreesign/migrate
```

## Features
- Real-time progress bar
- Direct old → new server streaming
- Automatic local backup (`./migration_data/`)
- Clean replace of all target paths
- Exact PM2 restoration
- Global npm packages reinstalled
- Requires passwordless SSH keys