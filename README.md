# DegreeSign | Apache + PM2 Server Migration Tool

One-command server migration for Ubuntu/Debian servers running Apache + PM2 + Node.js apps.

Migrates everything safely and exactly:
- Apache config
- Web files
- SSL certificates
- PM2 apps (original paths preserved via `dump.pm2`)
- Global npm packages

License: Apache-2.0 [LICENSE]

## Project Setup
### Directory Setup

```bash
# Create and enter your migration project folder
mkdir tmp_migration && cd tmp_migration

# Initialize a Yarn project (creates package.json)
yarn init -y

# Install the migration tool locally
yarn add server_migration

# Copy the example config and edit it
cp node_modules/@degreesign/migrate/.env.example .env
```

### Configuration Setup
Edit .env with your server details and paths
IMPORTANT:
* FOLLOWING DETAILS ARE JUST PLACEHOLDERS
* REVIEW AND UPDATE REQUIRED BEFORE USE

```env
# SSH details
OLD_USER=old_username
OLD_IP=0.0.0.0
NEW_USER=new_username
NEW_IP=1.1.1.1

# Comma-separated – no spaces after commas
MIGRATE_DIRS=/root/pm2_files,/var/www,/etc/letsencrypt
MIGRATE_FILES=/etc/apache2/apache2.conf,/etc/ssh/sshd_config
```
## Run
Run the migration

```bash
yarn migrate
```

## Features
- Real-time progress bar
- Direct old → new server streaming
- Automatic local backup (`./migration_data/`)
- Clean replace of all target paths
- Exact PM2 restoration
- Global npm packages reinstalled
- Requires passwordless SSH keys