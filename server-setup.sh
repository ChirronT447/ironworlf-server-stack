#!/bin/bash

# --- CONFIGURATION ---
IRONWOLF="/mnt/ironwolf"
NVME_STACK="$HOME/server-stack"
USER_NAME=$(whoami)
STEAM_PASS="your_secure_password" # Change this before running!

echo "🚀 Starting the HP Pro Mini Ultimate Setup..."

# 1. System Update & Drivers (GPU + DVB-T)
echo "📦 Updating system and installing drivers..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl intel-gpu-tools mesa-va-drivers intel-media-va-driver-non-free dvb-tools jq

# Fix for Sweex DVB-T (Firmware Download)
sudo wget -O /lib/firmware/dvb-usb-rtl2832-02.fw https://github.com/OpenELEC/dvb-firmware/raw/master/firmware/dvb-usb-rtl2832-02.fw

# 2. Install Docker
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER_NAME
else
    echo "🐳 Docker already installed."
fi

# 3. Create Partitioned Folders (NVMe for DBs, IronWolf for Files)
echo "📁 Organizing Storage (NVMe vs IronWolf)..."
mkdir -p $NVME_STACK/{immich-db,jellyfin-config,steam-config,beszel-data,tvheadend-config}
sudo mkdir -p $IRONWOLF/{photos,movies,steam-library,backups/weekly,backups/latest}
sudo chown -R $USER_NAME:$USER_NAME $IRONWOLF $NVME_STACK

# 4. Generate .env file
echo "🔐 Generating .env file..."
cat <<EOF > $NVME_STACK/.env
DB_PASSWORD=$(openssl rand -hex 16)
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
UPLOAD_LOCATION=$IRONWOLF/photos
IMMICH_VERSION=release
IMMICH_PROFILES_HWACCEL=vaapi
STEAM_PASS=$STEAM_PASS
EOF

# 5. Generate Docker Compose
echo "📝 Writing docker-compose.yml..."
cat <<EOF > $NVME_STACK/docker-compose.yml
services:
  # GAMING: Plasma (Sunshine/Steam)
  steam:
    image: jsmrcaga/plasma:latest
    container_name: steam-plasma
    privileged: true
    network_mode: host
    devices: ["/dev/dri:/dev/dri"]
    environment:
      - PASSWORD=\${STEAM_PASS}
      - GPU_TYPE=intel
      - DISPLAY_WIDTH=1920
      - DISPLAY_HEIGHT=1080
      - SUNSHINE_PASS=\${STEAM_PASS}
    volumes:
      - $NVME_STACK/steam-config:/home/steam/.local/share/Steam
      - $IRONWOLF/steam-library:/home/steam/SteamLibrary
      - /dev/input:/dev/input:ro # Hardware Gamepad passthrough
      - /run/udev:/run/udev:ro   # Hot-plugging detection
    restart: unless-stopped

  # PHOTOS: Immich
  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich_server
    devices: ["/dev/dri:/dev/dri"]
    volumes:
      - $IRONWOLF/photos:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file: [.env]
    ports: ["2283:3001"]
    depends_on: [database, valkey]
    restart: unless-stopped

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    container_name: immich_ml
    devices: ["/dev/dri:/dev/dri"]
    env_file: [.env]
    restart: unless-stopped

  database:
    image: ghcr.io/immich-app/postgres:16-vectorchord
    container_name: immich_postgres
    environment:
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_USER: \${DB_USERNAME}
      POSTGRES_DB: \${DB_DATABASE_NAME}
    volumes: ["$NVME_STACK/immich-db:/var/lib/postgresql/data"]
    restart: unless-stopped

  valkey:
    image: valkey/valkey:8-alpine
    container_name: immich_valkey
    restart: unless-stopped

  # MEDIA: Jellyfin
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    network_mode: host
    devices: ["/dev/dri:/dev/dri"]
    volumes:
      - $NVME_STACK/jellyfin-config:/config
      - $IRONWOLF/movies:/data
    restart: unless-stopped

  # TV: Tvheadend
  tvheadend:
    image: linuxserver/tvheadend:latest
    container_name: tvheadend
    network_mode: host
    devices: ["/dev/dvb:/dev/dvb"]
    volumes: ["$NVME_STACK/tvheadend-config:/config"]
    restart: unless-stopped

  # MONITORING: Beszel
  beszel-hub:
    image: henrygd/beszel:latest
    container_name: beszel-hub
    ports: ["8090:8090"]
    volumes: ["$NVME_STACK/beszel-data:/beszel_data"]
    restart: unless-stopped

  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]
    devices: ["/dev/dri:/dev/dri"]
    environment:
      - PORT=4567
      - KEY="PLACEHOLDER" # Update this from Beszel UI later
    restart: unless-stopped
EOF

# 6. Generate Maintenance & Rollback Script
echo "🛠️ Creating maintain.sh..."
cat <<EOF > $NVME_STACK/maintain.sh
#!/bin/bash
source $NVME_STACK/.env

BACKUP_DIR="$IRONWOLF/backups/latest"
WEEKLY_DIR="$IRONWOLF/backups/weekly"
DATE_STAMP=\$(date +%F_%H-%M)

mkdir -p "\$BACKUP_DIR" "\$WEEKLY_DIR"
cd "$NVME_STACK"

backup_all() {
    echo "📸 Snapshotting for maintenance/backup..."
    docker tag jsmrcaga/plasma:latest jsmrcaga/plasma:previous 2>/dev/null
    docker tag ghcr.io/immich-app/immich-server:release ghcr.io/immich-app/immich-server:previous 2>/dev/null
    
    echo "🔹 Dumping Immich Database..."
    docker exec -t immich_postgres pg_dumpall -U \$DB_USERNAME > "\$BACKUP_DIR/immich_db.sql"
    
    echo "🔹 Zipping NVMe configs..."
    tar -czf "\$BACKUP_DIR/configs_backup.tar.gz" -C "$HOME" "server-stack"
    
    if [ "\$(date +%u)" -eq 7 ]; then
        echo "🔹 Creating Weekly Archive..."
        cp "\$BACKUP_DIR/configs_backup.tar.gz" "\$WEEKLY_DIR/config_\$DATE_STAMP.tar.gz"
    fi
    echo "✅ Backup Complete."
}

update_all() {
    echo "🚀 Pulling new images..."
    docker compose pull
    echo "🔄 Restarting containers with updates..."
    docker compose up -d --remove-orphans
    echo "🧹 Cleaning up old unused images..."
    docker image prune -f
    echo "✅ Update Complete."
}

case "\$1" in
    backup) backup_all ;;
    update) backup_all && update_all ;;
    check) docker compose pull --quiet && echo "Updates pulled. Run './maintain.sh update' to apply." ;;
    shutdown) backup_all && docker compose pull ;;
    rollback) 
        echo "⚠️ Rolling back to previous images..."
        sed -i 's/:latest/:previous/g' docker-compose.yml
        sed -i 's/:release/:previous/g' docker-compose.yml
        docker compose up -d
        ;;
    *) echo "Usage: \$0 {backup|update|check|shutdown|rollback}" ;;
esac
EOF
chmod +x $NVME_STACK/maintain.sh

# 7. Generate Gaming Mode Toggle Script
echo "🎮 Creating gaming-mode.sh..."
cat <<EOF > $NVME_STACK/gaming-mode.sh
#!/bin/bash
case "\$1" in
    on)
        echo "🎮 Activating Gaming Mode..."
        echo "Pausing background hogs (Immich, Jellyfin, Tvheadend)..."
        docker pause immich_server immich_ml jellyfin tvheadend
        echo "✅ GPU is now completely dedicated to Steam!"
        ;;
    off)
        echo "🛑 Deactivating Gaming Mode..."
        echo "Waking up background apps..."
        docker unpause immich_server immich_ml jellyfin tvheadend
        echo "✅ Media and photo backups are active again."
        ;;
    *)
        echo "Usage: ./gaming-mode.sh {on|off}"
        ;;
esac
EOF
chmod +x $NVME_STACK/gaming-mode.sh

# 8. Install GE-Proton for Steam
echo "🎮 Fetching the latest GE-Proton for Steam compatibility..."
PROTON_DIR="$NVME_STACK/steam-config/compatibilitytools.d"
mkdir -p "$PROTON_DIR"

# Fetch the latest release download URL from GitHub API
GE_URL=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')

if [ -n "$GE_URL" ]; then
    echo "Downloading and extracting GE-Proton..."
    curl -sL "$GE_URL" | tar -xz -C "$PROTON_DIR"
    echo "✅ GE-Proton successfully installed."
else
    echo "⚠️ Could not automatically fetch GE-Proton. You can add it manually later."
fi

# 9. Create Systemd Services (Shutdown Backup & Startup Check)
echo "⚙️ Configuring Systemd Services..."
sudo cat <<EOF > /etc/systemd/system/maintenance-on-shutdown.service
[Unit]
Description=Backup and Update Pull on Shutdown
After=docker.service mnt-ironwolf.mount
Requires=mnt-ironwolf.mount

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=$NVME_STACK/maintain.sh shutdown
User=$USER_NAME

[Install]
WantedBy=multi-user.target
EOF

sudo cat <<EOF > /etc/systemd/system/stack-check.service
[Unit]
Description=Check for Docker Stack Updates on Startup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=$USER_NAME
WorkingDirectory=$NVME_STACK
ExecStart=$NVME_STACK/maintain.sh check
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable maintenance-on-shutdown.service
sudo systemctl enable stack-check.service

echo "----------------------------------------------------"
echo "✅ ALL SET! Your ultimate stack script has finished."
echo "1. Log out and log back in (so Docker permissions take effect)."
echo "2. Run: cd $NVME_STACK && docker compose up -d"
echo "3. Remember to run './gaming-mode.sh on' before you game!"
