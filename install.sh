#!/usr/bin/env bash
set -uo pipefail

#############################################
# Matrix Stack Manager - v2.0
# PostgreSQL + LiveKit + MAS Edition  
# GitHub: https://github.com/VeilVulp
#############################################

LOG_FILE="/var/log/matrix_stack_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

CONFIG_FILE="/etc/matrix-stack.conf"
VERSION="2.0"

read -r -d '' ASCII_BANNER <<'BANNER'
╔══════════════════════════════════════════════════════════════════════╗
║  _____                    ______ _                                   ║
║ |  ___|                   |  ___| |                                  ║
║ | |__  __ _ __ ___  _   _ | |__ | | ___ _ __ ___   ___ _ __ | |_     ║
║ |  __|/ _` / __| | | | | ||  __|| |/ _ \ '_ ` _ \ / _ \ '_ \| __|    ║
║ | |__| (_| \__ \ |_| | | || |___| |  __/ | | | | |  __/ | | | |_     ║
║ \____/\__,_|___/\__, | \/ \____/|_|\___|_| |_| |_|\___|_| |_|\__|    ║
║                  __/ |                                               ║
║                 |___/                                                ║
╚══════════════════════════════════════════════════════════════════════╝


BANNER


#############################################
# Helpers
#############################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}✅ [INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠️  [WARN]${NC} $*"; }
log_error() { echo -e "${RED}❌ [ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}▶ $*${NC}"; }

fail() {
  log_error "$1"
  echo "📝 Check the log file: ${LOG_FILE}"
  echo "💡 You can run option 11 (Fix Wizard) to attempt auto-repair."
  pause
  return 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as ROOT (sudo -i)."
    exit 1
  fi
}

print_header() {
  clear || true
  echo "$ASCII_BANNER"
  echo "🚀 Matrix Stack Manager v${VERSION} (PostgreSQL + LiveKit + MAS)"
  echo "� GitHub: https://github.com/VeilVulp/Easy-Element"
  echo "📝 Log file: ${LOG_FILE}"
  echo
}

pause() {
  read -rp "Press Enter to continue..." _
}

save_config() {
  mkdir -p "$(dirname "${CONFIG_FILE}")"
  cat > "${CONFIG_FILE}" <<EOF
HS_DOMAIN=${HS_DOMAIN}
ELEMENT_DOMAIN=${ELEMENT_DOMAIN}
BASE_DOMAIN=${BASE_DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
LE_EMAIL=${LE_EMAIL}
PG_USER=${PG_USER:-synapse_user}
PG_PASS=${PG_PASS:-}
PG_DB=${PG_DB:-synapse}
MAS_DOMAIN=${MAS_DOMAIN:-}
MAS_SECRET=${MAS_SECRET:-}
MAS_PG_USER=${MAS_PG_USER:-mas_user}
MAS_PG_PASS=${MAS_PG_PASS:-}
MAS_PG_DB=${MAS_PG_DB:-mas}
LIVEKIT_DOMAIN=${LIVEKIT_DOMAIN:-}
LIVEKIT_KEY=${LIVEKIT_KEY:-}
LIVEKIT_SECRET=${LIVEKIT_SECRET:-}
EOF
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    return 0
  fi
  return 1
}

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

generate_strong_password() {
  openssl rand -base64 24 | tr -d '\n' | tr -d '=' | tr '/+' 'Aa'
}

ensure_postgres_installed() {
  if ! command -v psql >/dev/null 2>&1; then
    log_step "📦 Installing PostgreSQL..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib libpq5
  fi
  ensure_postgres_running
}

ensure_postgres_running() {
  # First, make sure PostgreSQL packages are actually installed
  if ! dpkg -l postgresql 2>/dev/null | grep -q '^ii'; then
    log_warn "PostgreSQL package not installed. Installing now..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
      postgresql postgresql-contrib libpq5 || {
      log_error "Failed to install PostgreSQL packages."
      return 1
    }
  fi

  # Fix broken PostgreSQL cluster if data dir is missing
  local PG_VER
  PG_VER=$(pg_lsclusters -h 2>/dev/null | head -1 | awk '{print $1}')
  if [[ -z "${PG_VER}" ]]; then
    PG_VER="16"  # default for Ubuntu 24.04
  fi
  local PG_CLUSTER
  PG_CLUSTER=$(pg_lsclusters -h 2>/dev/null | head -1 | awk '{print $2}')
  if [[ -z "${PG_CLUSTER}" ]]; then
    PG_CLUSTER="main"
  fi
  local PG_DATA="/var/lib/postgresql/${PG_VER}/${PG_CLUSTER}"

  # Check if cluster data directory exists and is healthy
  if [[ ! -d "${PG_DATA}" ]] || [[ ! -f "${PG_DATA}/PG_VERSION" ]]; then
    log_warn "PostgreSQL data directory missing or corrupt: ${PG_DATA}"
    log_step "Repairing PostgreSQL cluster ${PG_VER}/${PG_CLUSTER}..."
    # Verify pg_createcluster is available
    if ! command -v pg_createcluster >/dev/null 2>&1; then
      log_warn "pg_createcluster not found. Installing postgresql-common..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
        postgresql-common postgresql-client-common "postgresql-${PG_VER}" || {
        log_error "Failed to install postgresql-common. Cannot repair cluster."
        return 1
      }
    fi
    systemctl stop "postgresql@${PG_VER}-${PG_CLUSTER}" 2>/dev/null || true
    pg_dropcluster --stop "${PG_VER}" "${PG_CLUSTER}" 2>/dev/null || true
    pg_createcluster "${PG_VER}" "${PG_CLUSTER}" --start || {
      log_error "pg_createcluster failed."
      return 1
    }
    log_info "PostgreSQL cluster recreated."
  fi

  # Ensure the specific cluster service is running
  systemctl enable postgresql 2>/dev/null || true
  systemctl enable "postgresql@${PG_VER}-${PG_CLUSTER}" 2>/dev/null || true
  if ! systemctl is-active --quiet "postgresql@${PG_VER}-${PG_CLUSTER}"; then
    log_step "Starting postgresql@${PG_VER}-${PG_CLUSTER}..."
    systemctl start "postgresql@${PG_VER}-${PG_CLUSTER}" || {
      log_error "Failed to start postgresql@${PG_VER}-${PG_CLUSTER}"
      journalctl -xeu "postgresql@${PG_VER}-${PG_CLUSTER}" --no-pager -n 20
      return 1
    }
  fi

  # Wait for PostgreSQL to truly accept connections
  wait_for_postgres
}

wait_for_postgres() {
  log_step "⏳ Waiting for PostgreSQL to accept connections..."
  local max_retries=30
  local i
  for i in $(seq 1 ${max_retries}); do
    if sudo -u postgres pg_isready -h /var/run/postgresql -q 2>/dev/null; then
      log_info "PostgreSQL is ready (attempt ${i}/${max_retries})."
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo
  log_error "PostgreSQL did NOT become ready after ${max_retries} seconds."
  log_error "Run: systemctl status postgresql && journalctl -xeu postgresql@*"
  return 1
}

safe_systemctl() {
  local action="$1"
  local service="$2"
  local critical="${3:-false}"

  systemctl "${action}" "${service}" 2>/dev/null
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if [[ "${critical}" == "true" ]]; then
      log_error "Failed to ${action} ${service} (exit code: ${rc})"
      journalctl -xeu "${service}" --no-pager -n 15
      return 1
    else
      log_warn "${action} ${service} returned code ${rc} (non-critical, continuing)"
    fi
  else
    if [[ "${action}" == "start" || "${action}" == "restart" || "${action}" == "enable" ]]; then
      log_info "${service}: ${action} OK"
    fi
  fi
  return 0
}

validate_download() {
  local file="$1"
  local desc="$2"

  if [[ ! -f "${file}" ]]; then
    log_error "Download failed: ${desc} — file not found: ${file}"
    return 1
  fi
  local size
  size=$(stat --printf='%s' "${file}" 2>/dev/null || stat -f '%z' "${file}" 2>/dev/null || echo "0")
  if [[ "${size}" -lt 1000 ]]; then
    log_error "Download failed: ${desc} — file too small (${size} bytes): ${file}"
    rm -f "${file}" || true
    return 1
  fi
  log_info "Downloaded ${desc} (${size} bytes)"
  return 0
}

restart_services() {
  safe_systemctl restart matrix-synapse || true
  safe_systemctl restart coturn || true
  safe_systemctl restart livekit-server || true
  safe_systemctl restart lk-jwt-service || true
  safe_systemctl restart mas || true
  systemctl reload nginx 2>/dev/null || true
}

detect_arch() {
  uname -m
}

#############################################
# Install / Reinstall
#############################################

install_stack() {
  print_header
  echo "🧩 === Matrix Full Stack Installer (PostgreSQL + LiveKit + MAS) ==="
  echo

  read -rp "🌐 Enter Matrix homeserver domain (e.g. chat.example.com): " HS_DOMAIN
  read -rp "🧭 Enter Element Web domain (e.g. app.example.com): " ELEMENT_DOMAIN
  read -rp "🏠 Enter base domain for .well-known (e.g. example.com): " BASE_DOMAIN
  read -rp "📌 Enter server public IP (e.g. 1.2.3.4): " PUBLIC_IP
  read -rp "✉️  Enter email for Let's Encrypt notifications: " LE_EMAIL
  read -rp "📹 Enter LiveKit domain (e.g. livekit.example.com): " LIVEKIT_DOMAIN
  read -rp "🔐 Enter MAS auth domain (e.g. auth.example.com): " MAS_DOMAIN

  if [[ -z "${HS_DOMAIN}" || -z "${ELEMENT_DOMAIN}" || -z "${BASE_DOMAIN}" || -z "${PUBLIC_IP}" || -z "${LE_EMAIL}" || -z "${LIVEKIT_DOMAIN}" || -z "${MAS_DOMAIN}" ]]; then
    echo "❌ All fields are required. Aborting install."
    pause
    return 1
  fi

  # Auto-generate strong passwords
  PG_USER="synapse_user"
  PG_PASS="$(generate_strong_password)"
  PG_DB="synapse"
  MAS_PG_USER="mas_user"
  MAS_PG_PASS="$(generate_strong_password)"
  MAS_PG_DB="mas"
  MAS_SECRET="$(openssl rand -hex 32)"
  LIVEKIT_KEY="$(openssl rand -hex 16)"
  LIVEKIT_SECRET="$(openssl rand -hex 32)"

  echo
  echo "============ INSTALL CONFIGURATION SUMMARY ============"
  echo "Matrix Homeserver:    ${HS_DOMAIN}"
  echo "Element Web:          ${ELEMENT_DOMAIN}"
  echo "Base Domain:          ${BASE_DOMAIN}"
  echo "Public IP:            ${PUBLIC_IP}"
  echo "Let's Encrypt Email:  ${LE_EMAIL}"
  echo "LiveKit Domain:       ${LIVEKIT_DOMAIN}"
  echo "MAS Auth Domain:      ${MAS_DOMAIN}"
  echo "-------------------------------------------------------"
  echo "PostgreSQL User:      ${PG_USER}"
  echo "PostgreSQL DB:        ${PG_DB}"
  echo "PostgreSQL Password:  (auto-generated, shown after install)"
  echo "======================================================="
  echo
  read -rp "✅ Continue with installation? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "❎ Install aborted."
    pause
    return 1
  fi

  save_config

  export DEBIAN_FRONTEND=noninteractive

  echo
  log_step "📦 [1/20] Updating system & installing dependencies..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget gnupg lsb-release \
    nginx certbot python3-certbot-nginx \
    coturn debconf-utils jq \
    postgresql postgresql-contrib libpq5 || {
    log_warn "Some packages failed to install, retrying with --fix-missing..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
      ca-certificates curl wget gnupg lsb-release \
      nginx certbot python3-certbot-nginx \
      coturn debconf-utils jq \
      postgresql postgresql-contrib libpq5 || {
      fail "Critical packages could not be installed. Check your network connection and apt sources."
      return 1
    }
  }
  # Verify critical packages are actually installed
  for pkg in nginx postgresql coturn; do
    if ! dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
      log_error "Package '${pkg}' is NOT installed after apt-get. Cannot continue."
      log_error "Try running: apt-get update && apt-get install -y --fix-missing ${pkg}"
      fail "Required package '${pkg}' is missing."
      return 1
    fi
  done
  log_info "All dependencies installed successfully."

  echo "➕ [2/20] Adding Matrix Synapse repository..."
  if [[ ! -f /usr/share/keyrings/matrix-org-archive-keyring.gpg ]]; then
    wget -4 -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
      https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  fi

  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list

  apt-get update

  echo "⚙️  [3/20] Pre-configuring Synapse (debconf)..."
  echo "matrix-synapse matrix-synapse/server-name string ${HS_DOMAIN}" | debconf-set-selections
  echo "matrix-synapse matrix-synapse/report-stats boolean false"      | debconf-set-selections

  echo "⬇️  [4/20] Installing Synapse..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y matrix-synapse-py3 || {
    fail "Failed to install matrix-synapse-py3. Check network and APT sources."
    return 1
  }

  log_step "🐘 [5/20] Setting up PostgreSQL database for Synapse..."

  # Robust PostgreSQL startup with cluster repair
  ensure_postgres_running || {
    fail "PostgreSQL could not be started. Cannot continue without a database."
    return 1
  }

  # Create Synapse database user and database
  log_step "Creating Synapse database user and database..."
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" 2>/dev/null | grep -q 1 \
    && sudo -u postgres psql -c "ALTER USER ${PG_USER} WITH PASSWORD '${PG_PASS}';" \
    || sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASS}';"
  if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" 2>/dev/null | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE ${PG_DB} ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0 OWNER ${PG_USER};" || {
      fail "Failed to create Synapse database '${PG_DB}'."
      return 1
    }
  else
    log_warn "Database ${PG_DB} already exists, setting owner..."
    sudo -u postgres psql -c "ALTER DATABASE ${PG_DB} OWNER TO ${PG_USER};" 2>/dev/null || true
  fi
  log_info "Synapse database ready: ${PG_DB}"

  log_step "🐘 [5.1/20] Setting up PostgreSQL database for MAS..."
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${MAS_PG_USER}'" 2>/dev/null | grep -q 1 \
    && sudo -u postgres psql -c "ALTER USER ${MAS_PG_USER} WITH PASSWORD '${MAS_PG_PASS}';" \
    || sudo -u postgres psql -c "CREATE USER ${MAS_PG_USER} WITH PASSWORD '${MAS_PG_PASS}';"
  if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${MAS_PG_DB}'" 2>/dev/null | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE ${MAS_PG_DB} ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0 OWNER ${MAS_PG_USER};" || {
      fail "Failed to create MAS database '${MAS_PG_DB}'."
      return 1
    }
  else
    log_warn "Database ${MAS_PG_DB} already exists, setting owner..."
    sudo -u postgres psql -c "ALTER DATABASE ${MAS_PG_DB} OWNER TO ${MAS_PG_USER};" 2>/dev/null || true
  fi
  log_info "MAS database ready: ${MAS_PG_DB}"

  echo "🔧 [6/20] Configuring Synapse for PostgreSQL..."
  cat > /etc/matrix-synapse/conf.d/database.yaml <<EOF
database:
  name: psycopg2
  args:
    user: ${PG_USER}
    password: "${PG_PASS}"
    dbname: ${PG_DB}
    host: 127.0.0.1
    cp_min: 5
    cp_max: 10
EOF

  echo "🧾 [7/20] Configuring Synapse registration..."
  REG_SECRET=$(openssl rand -hex 32)
  cat > /etc/matrix-synapse/conf.d/registration.yaml <<EOF
enable_registration: false
enable_registration_without_verification: false
password_config:
  enabled: false
registration_shared_secret: "${REG_SECRET}"
EOF

  echo "📦 [7.1/20] Configuring Synapse media defaults..."
  cat > /etc/matrix-synapse/conf.d/media.yaml <<EOF
max_upload_size: 50M
EOF

  echo "📞 [8/20] Configuring TURN for Synapse..."
  TURN_SECRET=$(openssl rand -hex 32)
  cat > /etc/matrix-synapse/conf.d/turn.yaml <<EOF
turn_uris:
  - "turn:${HS_DOMAIN}:3478?transport=udp"
  - "turns:${HS_DOMAIN}:5349?transport=tcp"

turn_shared_secret: "${TURN_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: true
EOF

  echo "🧪 [8.1/20] Configuring Synapse experimental features (MatrixRTC)..."
  cat > /etc/matrix-synapse/conf.d/experimental.yaml <<EOF
experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
max_event_delay_duration: 24h
rc_message:
  per_second: 1000
  burst_count: 1000
EOF

  echo "� [8.2/20] Configuring Synapse for MAS delegation..."
  cat > /etc/matrix-synapse/conf.d/mas.yaml <<EOF
matrix_authentication_service:
  enabled: true
  endpoint: http://127.0.0.1:8085/
  secret: "${MAS_SECRET}"
EOF

  echo "�🛰️  [9/20] Configuring coturn..."
  if grep -q "^TURNSERVER_ENABLED" /etc/default/coturn 2>/dev/null; then
    sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
  fi

  cat > /etc/turnserver.conf <<EOF
syslog
no-rfc5780
no-stun-backward-compatibility
response-origin-only-with-rfc5780

listening-port=3478
tls-listening-port=5349

listening-ip=${PUBLIC_IP}
relay-ip=${PUBLIC_IP}
external-ip=${PUBLIC_IP}

realm=${HS_DOMAIN}
server-name=${HS_DOMAIN}
fingerprint

cert=/etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem
pkey=/etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem

use-auth-secret
static-auth-secret=${TURN_SECRET}

min-port=49160
max-port=49200

total-quota=100
bps-capacity=0

no-loopback-peers
no-multicast-peers

verbose
EOF

  echo "🔒 [10/20] Requesting SSL certificates (certbot standalone)..."
  systemctl stop nginx || true

  certbot certonly --standalone \
    --non-interactive --agree-tos \
    -m "${LE_EMAIL}" \
    -d "${HS_DOMAIN}" \
    -d "${ELEMENT_DOMAIN}" \
    -d "${BASE_DOMAIN}" \
    -d "${LIVEKIT_DOMAIN}" \
    -d "${MAS_DOMAIN}" || {
    log_error "Certbot failed to obtain SSL certificates."
    log_error "Make sure all domains point to this server's IP (${PUBLIC_IP})."
    log_error "DNS must propagate before SSL can be issued."
    fail "SSL certificate request failed. Fix DNS and re-run install."
    return 1
  }

  systemctl start nginx

  log_step "📹 [11/20] Installing LiveKit Server..."
  curl -4 -sSL https://get.livekit.io | bash || {
    log_warn "LiveKit install script failed, trying manual download..."
    local LK_ARCH
    LK_ARCH="$(uname -m)"
    if [[ "${LK_ARCH}" == "x86_64" ]]; then LK_ARCH="amd64"; fi
    if [[ "${LK_ARCH}" == "aarch64" ]]; then LK_ARCH="arm64"; fi
    local LK_URL="https://github.com/livekit/livekit/releases/latest/download/livekit_linux_${LK_ARCH}.tar.gz"
    wget -4 -O /tmp/livekit.tar.gz "${LK_URL}"
    validate_download /tmp/livekit.tar.gz "LiveKit Server" || {
      fail "Could not download LiveKit Server."
      return 1
    }
    tar -xzf /tmp/livekit.tar.gz -C /usr/local/bin/ livekit-server
    chmod +x /usr/local/bin/livekit-server
    rm -f /tmp/livekit.tar.gz
  }
  if [[ ! -x /usr/local/bin/livekit-server ]]; then
    fail "LiveKit Server binary not found at /usr/local/bin/livekit-server"
    return 1
  fi
  log_info "LiveKit Server installed."

  echo "🔧 [11.1/20] Configuring LiveKit Server..."
  mkdir -p /etc/livekit
  cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
rtc:
  port_range_start: 50100
  port_range_end: 50200
  node_ip: ${PUBLIC_IP}
  use_external_ip: false
  tcp_port: 7881
turn:
  enabled: true
  domain: ${LIVEKIT_DOMAIN}
  tls_port: 4443
  external_tls: false
  cert_file: /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem
  key_file: /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem
keys:
  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}
room:
  auto_create: false
logging:
  level: info
EOF

  echo "📦 [11.2/20] Creating LiveKit systemd service..."
  cat > /etc/systemd/system/livekit-server.service <<EOF
[Unit]
Description=LiveKit Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log_step "📹 [12/20] Installing lk-jwt-service..."
  local JWT_ARCH
  JWT_ARCH="$(uname -m)"
  if [[ "${JWT_ARCH}" == "x86_64" ]]; then JWT_ARCH="amd64"; fi
  if [[ "${JWT_ARCH}" == "aarch64" ]]; then JWT_ARCH="arm64"; fi
  local JWT_URL="https://github.com/element-hq/lk-jwt-service/releases/latest/download/lk-jwt-service_linux_${JWT_ARCH}"
  wget -4 -O /usr/local/bin/lk-jwt-service "${JWT_URL}" || {
    log_warn "Could not download lk-jwt-service, trying alternative..."
    JWT_URL="https://github.com/element-hq/lk-jwt-service/releases/latest/download/lk-jwt-service-linux-${JWT_ARCH}"
    wget -4 -O /usr/local/bin/lk-jwt-service "${JWT_URL}"
  }
  validate_download /usr/local/bin/lk-jwt-service "lk-jwt-service" || {
    fail "Could not download lk-jwt-service."
    return 1
  }
  chmod +x /usr/local/bin/lk-jwt-service
  log_info "lk-jwt-service installed."

  echo "📦 [12.1/20] Creating lk-jwt-service systemd service..."
  cat > /etc/systemd/system/lk-jwt-service.service <<EOF
[Unit]
Description=LiveKit JWT Service for Matrix
After=network.target livekit-server.service

[Service]
Type=simple
Environment=LIVEKIT_URL=wss://${LIVEKIT_DOMAIN}
Environment=LIVEKIT_KEY=${LIVEKIT_KEY}
Environment=LIVEKIT_SECRET=${LIVEKIT_SECRET}
Environment=LIVEKIT_JWT_BIND=127.0.0.1:8881
ExecStart=/usr/local/bin/lk-jwt-service
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log_step "🔐 [13/20] Installing Matrix Authentication Service (MAS)..."
  local MAS_ARCH
  MAS_ARCH="$(uname -m)"
  mkdir -p /opt/mas
  local MAS_URL="https://github.com/element-hq/matrix-authentication-service/releases/latest/download/mas-cli-${MAS_ARCH}-linux.tar.gz"
  wget -4 -O /tmp/mas-cli.tar.gz "${MAS_URL}"
  validate_download /tmp/mas-cli.tar.gz "MAS CLI" || {
    fail "Could not download MAS CLI."
    return 1
  }
  tar -xzf /tmp/mas-cli.tar.gz -C /opt/mas/
  rm -f /tmp/mas-cli.tar.gz
  ln -sf /opt/mas/mas-cli /usr/local/bin/mas-cli
  if [[ ! -x /usr/local/bin/mas-cli ]]; then
    fail "MAS CLI binary not found after extraction."
    return 1
  fi
  log_info "MAS CLI installed."

  echo "🔧 [13.1/20] Generating MAS configuration..."
  mkdir -p /etc/mas
  mas-cli config generate > /etc/mas/config.yaml 2>/dev/null || true

  # Patch MAS config with our settings
  cat > /etc/mas/config.override.yaml <<EOF
database:
  uri: "postgresql://${MAS_PG_USER}:${MAS_PG_PASS}@127.0.0.1/${MAS_PG_DB}"

http:
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
      binds:
        - address: "127.0.0.1:8085"
  public_base: "https://${MAS_DOMAIN}/"
  issuer: "https://${MAS_DOMAIN}/"

matrix:
  homeserver: ${HS_DOMAIN}
  secret: "${MAS_SECRET}"
  endpoint: "http://127.0.0.1:8008"

policy:
  wasm_module: /opt/mas/share/policy.wasm

templates:
  path: /opt/mas/share/templates/

branding:
  service_name: "${HS_DOMAIN}"

account:
  email_change_allowed: true
  displayname_change_allowed: true
  password_change_allowed: true
  password_registration_enabled: true
  password_registration_email_required: false
EOF

  echo "📦 [13.2/20] Creating MAS systemd service..."
  cat > /etc/systemd/system/mas.service <<EOF
[Unit]
Description=Matrix Authentication Service
After=network.target postgresql.service

[Service]
Type=simple
Environment=MAS_CONFIG=/etc/mas/config.yaml:/etc/mas/config.override.yaml
ExecStart=/usr/local/bin/mas-cli server
Restart=always
RestartSec=5
WorkingDirectory=/opt/mas

[Install]
WantedBy=multi-user.target
EOF

  log_step "🗄️ [13.3/20] Running MAS database migration..."
  # Verify PostgreSQL is still running before MAS migration
  if ! sudo -u postgres pg_isready -h /var/run/postgresql -q 2>/dev/null; then
    log_warn "PostgreSQL lost connection, restarting before MAS migration..."
    ensure_postgres_running || {
      fail "PostgreSQL is not running. MAS migration cannot proceed."
      return 1
    }
  fi
  MAS_CONFIG=/etc/mas/config.yaml:/etc/mas/config.override.yaml mas-cli database migrate || {
    log_warn "MAS db migrate had issues, will retry after service start..."
  }
  MAS_CONFIG=/etc/mas/config.yaml:/etc/mas/config.override.yaml mas-cli config sync || {
    log_warn "MAS config sync had issues, will retry after service start..."
  }

  if command -v ufw >/dev/null 2>&1; then
    log_step "🔥 [14/20] Opening firewall ports (UFW)..."
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 3478/udp || true
    ufw allow 3478/tcp || true
    ufw allow 5349/tcp || true
    ufw allow 4443/tcp || true
    ufw allow 49160:49200/udp || true
    ufw allow 7881/tcp || true
    ufw allow 50100:50200/udp || true
  fi

  log_step "🔄 [15/20] Starting services (dependency order)..."
  systemctl daemon-reload

  # 1. PostgreSQL must be running first
  ensure_postgres_running || {
    fail "PostgreSQL failed to start. All dependent services will fail."
    return 1
  }

  # 2. Start matrix-synapse (depends on PostgreSQL)
  safe_systemctl restart matrix-synapse "true" || {
    log_error "matrix-synapse failed to start. Checking if database config is correct..."
    log_error "Verify: /etc/matrix-synapse/conf.d/database.yaml"
  }

  # 3. Start MAS (depends on PostgreSQL) - retry migration if it failed earlier
  if ! MAS_CONFIG=/etc/mas/config.yaml:/etc/mas/config.override.yaml mas-cli database migrate 2>/dev/null; then
    log_warn "MAS migration retry also failed — MAS may not work correctly."
  fi
  safe_systemctl enable mas || true
  safe_systemctl restart mas || log_warn "MAS failed to start (check config)"

  # 4. Start coturn
  safe_systemctl restart coturn || log_warn "coturn failed to start"

  # 5. Start LiveKit services
  safe_systemctl enable livekit-server || true
  safe_systemctl restart livekit-server || log_warn "livekit-server failed to start"
  safe_systemctl enable lk-jwt-service || true
  safe_systemctl restart lk-jwt-service || log_warn "lk-jwt-service failed to start"

  log_step "🧩 [16/20] Installing Element Web..."
  mkdir -p /var/www

  ELEMENT_VERSION="1.12.7"
  wget -4 -O /var/www/element.tar.gz "https://github.com/element-hq/element-web/releases/download/v${ELEMENT_VERSION}/element-v${ELEMENT_VERSION}.tar.gz"
  validate_download /var/www/element.tar.gz "Element Web v${ELEMENT_VERSION}" || {
    fail "Could not download Element Web."
    return 1
  }
  rm -rf /var/www/element || true
  tar -xvf /var/www/element.tar.gz -C /var/www/
  mv "/var/www/element-v${ELEMENT_VERSION}" /var/www/element
  rm -f /var/www/element.tar.gz
  log_info "Element Web v${ELEMENT_VERSION} installed."

  echo "🛠️  [17/20] Creating Element config.json..."
  cat > /var/www/element/config.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${HS_DOMAIN}",
      "server_name": "${HS_DOMAIN}"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": true,
  "brand": "Element"
}
EOF

  echo "🌍 [18/20] Creating Nginx virtual hosts..."

  # MATRIX vhost (with MAS compatibility proxy)
  cat > /etc/nginx/sites-available/matrix.conf <<EOF
server {
    listen 80;
    server_name ${HS_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${HS_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem;

    client_max_body_size 50M;

    # MAS compatibility endpoints
    location ~ ^/_matrix/client/(r0|v3)/(login|logout|refresh)\$ {
        proxy_pass http://127.0.0.1:8085;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }

    location = /.well-known/matrix/client {
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${HS_DOMAIN}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${LIVEKIT_DOMAIN}/livekit/jwt"}]}';
    }

    # Federation discovery — lk-jwt-service uses matrix:// protocol which
    # checks this endpoint first, then falls back to port 8448.
    # Without this, JWT token validation fails with "connection refused" on 8448.
    location = /.well-known/matrix/server {
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server":"${HS_DOMAIN}:443"}';
    }

    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf

  # ELEMENT vhost
  cat > /etc/nginx/sites-available/element.conf <<EOF
server {
    listen 80;
    server_name ${ELEMENT_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${ELEMENT_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem;

    root /var/www/element;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf

  # WELL-KNOWN vhost (with MatrixRTC focus for LiveKit)
  cat > /etc/nginx/sites-available/wellknown.conf <<EOF
server {
    listen 80;
    server_name ${BASE_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${BASE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem;

    location = /.well-known/matrix/client {
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${HS_DOMAIN}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${LIVEKIT_DOMAIN}/livekit/jwt"}]}';
    }

    location = /.well-known/matrix/server {
        add_header Content-Type application/json;
        return 200 '{"m.server":"${HS_DOMAIN}:443"}';
    }

    location / {
        return 404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/wellknown.conf /etc/nginx/sites-enabled/wellknown.conf

  # LIVEKIT vhost
  cat > /etc/nginx/sites-available/livekit.conf <<EOF
server {
    listen 80;
    server_name ${LIVEKIT_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${LIVEKIT_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem;

    # MatrixRTC Authorization Service (lk-jwt-service)
    # Official config from: https://github.com/element-hq/lk-jwt-service
    # NOTE: Do NOT add CORS headers here — lk-jwt-service handles CORS itself.
    # Adding them in Nginx causes duplicate "Access-Control-Allow-Origin: *, *"
    # which browsers strictly reject.
    location /livekit/jwt/ {
        proxy_pass http://127.0.0.1:8881/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # LiveKit SFU signaling (WebSocket)
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/livekit.conf /etc/nginx/sites-enabled/livekit.conf

  # MAS AUTH vhost
  cat > /etc/nginx/sites-available/mas-auth.conf <<EOF
server {
    listen 80;
    server_name ${MAS_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${MAS_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HS_DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8085;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/mas-auth.conf /etc/nginx/sites-enabled/mas-auth.conf

  rm -f /etc/nginx/sites-enabled/default || true

  echo "🔄 [19/20] Testing and reloading Nginx..."
  if ! nginx -t; then
    log_error "Nginx configuration test failed!"
    log_error "Check vhost files in /etc/nginx/sites-available/"
    fail "nginx -t failed. Fix config before continuing."
    return 1
  fi
  systemctl reload nginx

  log_step "🔄 [20/20] Final service verification..."
  safe_systemctl restart matrix-synapse || log_warn "matrix-synapse not running"
  safe_systemctl restart livekit-server || log_warn "livekit-server not running"
  safe_systemctl restart lk-jwt-service || log_warn "lk-jwt-service not running"
  safe_systemctl restart mas || log_warn "MAS not running"

  # Quick health check
  echo
  echo "🧠 Service Status:"
  for svc in postgresql matrix-synapse nginx coturn livekit-server lk-jwt-service mas; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      log_info "${svc}: active"
    else
      log_warn "${svc}: NOT active"
    fi
  done

  echo
  echo "======================================================="
  echo "✅ INSTALLATION COMPLETE"
  echo "-------------------------------------------------------"
  echo "Matrix Server:    https://${HS_DOMAIN}"
  echo "Element Web:      https://${ELEMENT_DOMAIN}"
  echo "Well-known:       https://${BASE_DOMAIN}"
  echo "LiveKit:          https://${LIVEKIT_DOMAIN}"
  echo "MAS Auth:         https://${MAS_DOMAIN}"
  echo "-------------------------------------------------------"
  echo "📊 DATABASE (PostgreSQL):"
  echo "  Synapse DB User:  ${PG_USER}"
  echo "  Synapse DB Pass:  ${PG_PASS}"
  echo "  Synapse DB Name:  ${PG_DB}"
  echo "  MAS DB User:      ${MAS_PG_USER}"
  echo "  MAS DB Pass:      ${MAS_PG_PASS}"
  echo "  MAS DB Name:      ${MAS_PG_DB}"
  echo "-------------------------------------------------------"
  echo "🔑 SECRETS:"
  echo "  Registration Secret: ${REG_SECRET}"
  echo "  TURN Secret:         ${TURN_SECRET}"
  echo "  MAS Secret:          ${MAS_SECRET}"
  echo "  LiveKit Key:         ${LIVEKIT_KEY}"
  echo "  LiveKit Secret:      ${LIVEKIT_SECRET}"
  echo "-------------------------------------------------------"
  echo "Log file:          ${LOG_FILE}"
  echo "Arch:              $(detect_arch)"
  echo "======================================================="
  echo
  echo "⚠️  IMPORTANT: Save these credentials! They are also stored in ${CONFIG_FILE}"
  echo

  pause
}

#############################################
# User Management
#############################################

create_admin_user() {
  print_header
  echo "👑 === Create ADMIN user ==="
  echo "Command:"
  echo "  register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml -a http://127.0.0.1:8008"
  echo
  register_new_matrix_user \
    -c /etc/matrix-synapse/conf.d/registration.yaml \
    -a \
    http://127.0.0.1:8008
  pause
}

create_normal_user() {
  print_header
  echo "👤 === Create NORMAL user ==="
  echo "Command:"
  echo "  register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml --no-admin http://127.0.0.1:8008"
  echo
  register_new_matrix_user \
    -c /etc/matrix-synapse/conf.d/registration.yaml \
    --no-admin \
    http://127.0.0.1:8008
  pause
}

create_user_random_password() {
  print_header
  echo "🎲 === Create user with RANDOM password ==="
  echo "This will generate a strong password and print it at the end."
  echo
  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Run Install first."
    pause
    return 1
  fi

  read -rp "Enter username (localpart, e.g. vahid): " LOCALPART
  if [[ -z "${LOCALPART}" ]]; then
    echo "❌ Username is required."
    pause
    return 1
  fi

  echo "Choose role:"
  echo "1) Normal user"
  echo "2) Admin user"
  read -rp "Choose [1-2]: " ROLE

  local PASS
  PASS="$(openssl rand -base64 18 | tr -d '\n' | tr -d '=' | tr '/+' 'Aa')"

  # Use temp password file to avoid exposing password in process list
  local TMPPASS
  TMPPASS="$(mktemp)"
  printf "%s" "${PASS}" > "${TMPPASS}"

  if [[ "${ROLE}" == "2" ]]; then
    register_new_matrix_user \
      -u "${LOCALPART}" \
      --password-file "${TMPPASS}" \
      -a \
      -c /etc/matrix-synapse/conf.d/registration.yaml \
      http://127.0.0.1:8008
    echo
    echo "✅ Created ADMIN user:"
  else
    register_new_matrix_user \
      -u "${LOCALPART}" \
      --password-file "${TMPPASS}" \
      --no-admin \
      -c /etc/matrix-synapse/conf.d/registration.yaml \
      http://127.0.0.1:8008
    echo
    echo "✅ Created NORMAL user:"
  fi

  rm -f "${TMPPASS}" || true

  echo "MXID:     @${LOCALPART}:${HS_DOMAIN}"
  echo "Password: ${PASS}"
  echo
  echo "Tip: Save this password now."
  pause
}

reactivate_user() {
  print_header
  echo "♻️  === Reactivate existing user (set new password) ==="
  echo "Tip: If the user was deactivated, this will re-enable it."
  echo "Command uses --exists-ok."
  echo
  echo "Choose reactivation type:"
  echo "1) Reactivate as NORMAL user"
  echo "2) Reactivate as ADMIN user"
  echo "3) Back"
  read -rp "Choose [1-3]: " ROPT

  case "${ROPT}" in
    1)
      register_new_matrix_user \
        --exists-ok \
        -c /etc/matrix-synapse/conf.d/registration.yaml \
        --no-admin \
        http://127.0.0.1:8008
      ;;
    2)
      register_new_matrix_user \
        --exists-ok \
        -c /etc/matrix-synapse/conf.d/registration.yaml \
        -a \
        http://127.0.0.1:8008
      ;;
    3) ;;
    *) echo "Invalid option." ;;
  esac

  pause
}

#############################################
# User Listing / Deactivation
#############################################

list_users() {
  print_header
  echo "📋 === List users (PostgreSQL) ==="
  ensure_postgres_installed

  if ! load_config; then
    echo "⚠️  Config not found. Run Install first."
    pause
    return 1
  fi

  echo "Format: MXID | admin(0/1) | deactivated(0/1)"
  echo "-------------------------------------------"
  sudo -u postgres psql -d "${PG_DB:-synapse}" -c \
    "SELECT name, admin, deactivated FROM users ORDER BY name;" 2>/dev/null || {
    echo "❌ Could not query PostgreSQL database."
    echo "Make sure PostgreSQL is running and the database exists."
  }

  pause
}

deactivate_user() {
  print_header
  echo "🚫 === Deactivate user (safe) ==="
  echo "This will:"
  echo " - Set deactivated=1"
  echo " - Clear password_hash"
  echo "It does NOT hard-delete messages/rooms (recommended)."
  echo
  read -rp "Enter full MXID (e.g. @user:example.com): " MXID

  if [[ -z "${MXID}" ]]; then
    echo "❌ MXID is required."
    pause
    return 1
  fi

  if ! load_config; then
    echo "⚠️  Config not found. Run Install first."
    pause
    return 1
  fi

  ensure_postgres_installed

  read -rp "Are you sure you want to deactivate ${MXID}? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  sudo -u postgres psql -d "${PG_DB:-synapse}" -c \
    "UPDATE users SET deactivated=1, password_hash=NULL WHERE name='${MXID}';" 2>/dev/null || {
    echo "❌ Could not update PostgreSQL database."
  }

  echo "✅ User ${MXID} has been deactivated."
  echo "Tip: Use Reactivate to enable it again and set a new password."
  pause
}

show_db_info() {
  print_header
  echo "📊 === Database Information ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Run Install first."
    pause
    return 1
  fi

  echo "🐘 Synapse PostgreSQL Database:"
  echo "  Host:     127.0.0.1"
  echo "  User:     ${PG_USER:-synapse_user}"
  echo "  Password: ${PG_PASS:-N/A}"
  echo "  Database: ${PG_DB:-synapse}"
  echo
  echo "🔐 MAS PostgreSQL Database:"
  echo "  Host:     127.0.0.1"
  echo "  User:     ${MAS_PG_USER:-mas_user}"
  echo "  Password: ${MAS_PG_PASS:-N/A}"
  echo "  Database: ${MAS_PG_DB:-mas}"
  echo
  echo "📹 LiveKit Credentials:"
  echo "  Domain:   ${LIVEKIT_DOMAIN:-N/A}"
  echo "  API Key:  ${LIVEKIT_KEY:-N/A}"
  echo "  Secret:   ${LIVEKIT_SECRET:-N/A}"
  echo
  echo "🔐 MAS Info:"
  echo "  Domain:   ${MAS_DOMAIN:-N/A}"
  echo "  Secret:   ${MAS_SECRET:-N/A}"
  echo

  pause
}

#############################################
# Upload limits management
#############################################

set_upload_limits() {
  print_header
  echo "📦 === Upload Limits Manager ==="
  echo "This option will set BOTH:"
  echo " - Nginx client_max_body_size (Matrix vhost)"
  echo " - Synapse max_upload_size"
  echo
  echo "Enter size in MB (e.g. 500, 2000, 5000)."
  read -rp "Upload limit (MB): " LIMIT_MB

  if [[ -z "${LIMIT_MB}" || ! "${LIMIT_MB}" =~ ^[0-9]+$ ]]; then
    echo "❌ Please enter a numeric value (MB)."
    pause
    return 1
  fi

  local LIMIT_NGINX="${LIMIT_MB}M"
  local LIMIT_SYNAPSE="${LIMIT_MB}M"

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}."
    echo "Run Install first so domains are known."
    pause
    return 1
  fi

  echo "✅ Setting Nginx upload limit to: ${LIMIT_NGINX}"
  if [[ -f /etc/nginx/sites-available/matrix.conf ]]; then
    if grep -q "client_max_body_size" /etc/nginx/sites-available/matrix.conf; then
      sed -i "s/client_max_body_size.*/client_max_body_size ${LIMIT_NGINX};/g" /etc/nginx/sites-available/matrix.conf
    else
      sed -i "/ssl_certificate_key/a\\
\\
    client_max_body_size ${LIMIT_NGINX};\\
" /etc/nginx/sites-available/matrix.conf
    fi
  else
    echo "❌ /etc/nginx/sites-available/matrix.conf not found."
    pause
    return 1
  fi

  echo "✅ Setting Synapse upload limit to: ${LIMIT_SYNAPSE}"
  mkdir -p /etc/matrix-synapse/conf.d
  cat > /etc/matrix-synapse/conf.d/media.yaml <<EOF
max_upload_size: ${LIMIT_SYNAPSE}
EOF

  echo "🔄 Reloading services..."
  nginx -t
  systemctl reload nginx
  systemctl restart matrix-synapse

  echo "🎉 Done! Upload limits updated."
  echo "Nginx:   client_max_body_size ${LIMIT_NGINX}"
  echo "Synapse: max_upload_size ${LIMIT_SYNAPSE}"
  echo
  echo "Tip: Hard refresh Element Web (Ctrl+Shift+R) if you still see old limits."
  pause
}

#############################################
# Toggle registration ON/OFF
#############################################

toggle_registration() {
  print_header
  echo "🧾 === Toggle Registration (ON/OFF) ==="
  echo "If OFF: users cannot sign up in Element (web/mobile)."
  echo "You can still create users via this script."
  echo

  if [[ ! -f /etc/mas/config.override.yaml ]]; then
    echo "❌ /etc/mas/config.override.yaml not found."
    pause
    return 1
  fi

  local current="unknown"
  if grep -q "password_registration_enabled:" /etc/mas/config.override.yaml; then
    current="$(grep "password_registration_enabled:" /etc/mas/config.override.yaml | awk '{print $2}' | tr -d '\r')"
  fi

  echo "Current password_registration_enabled: ${current}"
  echo
  echo "1) Turn ON registration"
  echo "2) Turn OFF registration"
  echo "3) Back"
  read -rp "Choose [1-3]: " opt

  case "${opt}" in
    1)
      if grep -q "password_registration_enabled:" /etc/mas/config.override.yaml; then
        sed -i 's/password_registration_enabled:.*/password_registration_enabled: true/' /etc/mas/config.override.yaml
      fi
      ;;
    2)
      if grep -q "password_registration_enabled:" /etc/mas/config.override.yaml; then
        sed -i 's/password_registration_enabled:.*/password_registration_enabled: false/' /etc/mas/config.override.yaml
      fi
      ;;
    3) ;;
    *) echo "Invalid option." ;;
  esac

  systemctl restart mas || true
  echo "✅ Updated. MAS restarted."
  pause
}

#############################################
# Call Diagnostics (TURN/WebRTC troubleshooting)
#############################################

call_diagnostics() {
  print_header
  echo "📞 === Call Diagnostics (TURN/WebRTC) ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Some checks will be limited."
  fi

  ensure_pkg coturn
  ensure_pkg curl
  ensure_pkg iproute2

  echo "🧠 Services:"
  systemctl is-active --quiet coturn && echo "✅ coturn: active" || echo "❌ coturn: NOT active"
  systemctl is-active --quiet matrix-synapse && echo "✅ matrix-synapse: active" || echo "❌ matrix-synapse: NOT active"
  echo

  echo "🧷 TURN ports listening (server-side):"
  ss -lunpt | grep -E ':(3478|5349)\b' || echo "❌ Not listening on 3478/5349 (check coturn config/service)."
  echo

  echo "🧾 TURN configuration summary:"
  if [[ -f /etc/turnserver.conf ]]; then
    echo "----- /etc/turnserver.conf (important lines) -----"
    grep -E '^(listening-port|tls-listening-port|listening-ip|relay-ip|external-ip|realm|server-name|min-port|max-port|use-auth-secret|static-auth-secret|cert=|pkey=)' /etc/turnserver.conf || true
    echo "--------------------------------------------------"
  else
    echo "❌ /etc/turnserver.conf not found."
  fi
  echo

  echo "🔥 Firewall quick check (UFW if available):"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
    echo
    echo "Expected UFW rules (at minimum):"
    echo " - 3478/udp, 3478/tcp, 5349/tcp"
    echo " - 49160:49200/udp (TURN relay ports)"
  else
    echo "⚠️  UFW not installed. If you use cloud firewall, check it there."
    echo "Required ports:"
    echo " - UDP 3478"
    echo " - TCP 3478"
    echo " - TCP 5349"
    echo " - UDP 49160-49200 (relay ports)"
  fi
  echo

  echo "🌐 Public reachability (informational):"
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    echo "Public IP set in config: ${PUBLIC_IP}"
  else
    echo "Public IP not loaded from config."
  fi
  echo

  echo "🧪 Synapse TURN config file:"
  if [[ -f /etc/matrix-synapse/conf.d/turn.yaml ]]; then
    cat /etc/matrix-synapse/conf.d/turn.yaml
  else
    echo "❌ /etc/matrix-synapse/conf.d/turn.yaml not found."
  fi
  echo

  echo "🧪 Matrix client endpoint (if domain known):"
  if [[ -n "${HS_DOMAIN:-}" ]]; then
    if curl -4 -fsS "https://${HS_DOMAIN}/_matrix/client/versions" >/dev/null 2>&1; then
      echo "✅ https://${HS_DOMAIN}/_matrix/client/versions OK"
    else
      echo "❌ Cannot reach https://${HS_DOMAIN}/_matrix/client/versions"
      echo "   This can also break call setup in clients."
    fi
  else
    echo "⚠️  HS_DOMAIN not known (run Install first)."
  fi
  echo

  echo "📜 Recent coturn logs (last 80 lines):"
  journalctl -u coturn -n 80 --no-pager || true
  echo

  echo "📌 If calls stay on 'Connecting', the most common cause is:"
  echo " - UDP relay ports are blocked (49160-49200/udp) in server firewall OR cloud firewall."
  echo " - Or external-ip is wrong (NAT scenario)."
  echo
  echo "Tip: Try a test call, then immediately run this diagnostics and check for:"
  echo " - 'allocation timeout' in coturn logs."
  echo

  pause
}

#############################################
# Health Check
#############################################

health_check() {
  print_header
  echo "🔎 === Health Check ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Some URL checks will be skipped."
  fi

  echo "🧠 Services:"
  systemctl is-active --quiet matrix-synapse && echo "✅ matrix-synapse: active" || echo "❌ matrix-synapse: NOT active"
  systemctl is-active --quiet nginx && echo "✅ nginx: active" || echo "❌ nginx: NOT active"
  systemctl is-active --quiet coturn && echo "✅ coturn: active" || echo "❌ coturn: NOT active"
  systemctl is-active --quiet postgresql && echo "✅ postgresql: active" || echo "❌ postgresql: NOT active"
  systemctl is-active --quiet livekit-server && echo "✅ livekit-server: active" || echo "❌ livekit-server: NOT active"
  systemctl is-active --quiet lk-jwt-service && echo "✅ lk-jwt-service: active" || echo "❌ lk-jwt-service: NOT active"
  systemctl is-active --quiet mas && echo "✅ mas: active" || echo "❌ mas: NOT active"
  echo

  echo "🌐 Nginx config test:"
  if nginx -t >/dev/null 2>&1; then
    echo "✅ nginx -t OK"
  else
    echo "❌ nginx -t FAILED"
    nginx -t || true
  fi
  echo

  if [[ -n "${HS_DOMAIN:-}" ]]; then
    echo "🧪 Matrix client API:"
    if curl -4 -fsS "https://${HS_DOMAIN}/_matrix/client/versions" >/dev/null 2>&1; then
      echo "✅ https://${HS_DOMAIN}/_matrix/client/versions OK"
    else
      echo "❌ Cannot reach https://${HS_DOMAIN}/_matrix/client/versions"
    fi
    echo
  fi

  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    echo "🧪 .well-known:"
    if curl -4 -fsS "https://${BASE_DOMAIN}/.well-known/matrix/client" >/dev/null 2>&1; then
      echo "✅ https://${BASE_DOMAIN}/.well-known/matrix/client OK"
    else
      echo "❌ Cannot reach https://${BASE_DOMAIN}/.well-known/matrix/client"
    fi
    echo
  fi

  echo "🧷 Listening ports (quick view):"
  ss -lntup | grep -E '(:80|:443|:8008|:3478|:5349)\b' || echo "⚠️  No expected ports found (or ss output restricted)."
  echo

  echo "🔐 Certbot certificates (if present):"
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates 2>/dev/null | sed -n '1,120p' || true
  else
    echo "⚠️  certbot not installed."
  fi

  pause
}

#############################################
# Fix Wizard (common issues)
#############################################

fix_wizard() {
  print_header
  echo "🧰 === Fix Wizard (common issues) ==="
  echo "This tries to fix:"
  echo " - Missing Nginx symlinks"
  echo " - Default site enabled"
  echo " - coturn disabled"
  echo " - Reload/restart services"
  echo

  if grep -q "^TURNSERVER_ENABLED" /etc/default/coturn 2>/dev/null; then
    sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
  fi

  [[ -f /etc/nginx/sites-available/matrix.conf ]] && ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf || true
  [[ -f /etc/nginx/sites-available/element.conf ]] && ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf || true
  [[ -f /etc/nginx/sites-available/wellknown.conf ]] && ln -sf /etc/nginx/sites-available/wellknown.conf /etc/nginx/sites-enabled/wellknown.conf || true
  [[ -f /etc/nginx/sites-available/livekit.conf ]] && ln -sf /etc/nginx/sites-available/livekit.conf /etc/nginx/sites-enabled/livekit.conf || true
  [[ -f /etc/nginx/sites-available/mas-auth.conf ]] && ln -sf /etc/nginx/sites-available/mas-auth.conf /etc/nginx/sites-enabled/mas-auth.conf || true

  rm -f /etc/nginx/sites-enabled/default || true

  echo "✅ Running nginx -t ..."
  nginx -t || true

  echo "🔄 Restarting services..."
  systemctl restart coturn || true
  systemctl restart matrix-synapse || true
  systemctl restart postgresql || true
  systemctl restart livekit-server || true
  systemctl restart lk-jwt-service || true
  systemctl restart mas || true
  systemctl reload nginx || true

  echo "✅ Fix Wizard done."
  pause
}

#############################################
# Backup / Restore
#############################################

backup_server() {
  print_header
  echo "💾 === Backup Server ==="
  echo

  local backup_dir="/root/matrix-backups"
  mkdir -p "${backup_dir}"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local out="${backup_dir}/matrix-backup-${ts}.tar.gz"

  echo "Include /etc/letsencrypt in backup?"
  echo "1) Yes"
  echo "2) No"
  read -rp "Choose [1-2]: " inc

  local paths=(
    "/etc/matrix-synapse"
    "/etc/nginx/sites-available"
    "/etc/nginx/sites-enabled"
    "/etc/turnserver.conf"
    "/etc/livekit"
    "/etc/mas"
    "${CONFIG_FILE}"
  )

  if [[ "${inc}" == "1" ]]; then
    paths+=("/etc/letsencrypt")
  fi

  echo "Creating config backup: ${out}"
  tar -czf "${out}" "${paths[@]}" 2>/dev/null || tar -czf "${out}" "${paths[@]}"

  # PostgreSQL database dump
  local pg_dump_file="${backup_dir}/matrix-pgdump-${ts}.sql.gz"
  echo "Creating PostgreSQL dump: ${pg_dump_file}"
  sudo -u postgres pg_dumpall 2>/dev/null | gzip > "${pg_dump_file}" || {
    echo "⚠️  PostgreSQL dump failed (may not be installed)."
  }

  echo "✅ Backup created:"
  echo "Config: ${out}"
  echo "DB:     ${pg_dump_file}"
  pause
}

restore_backup() {
  print_header
  echo "♻️  === Restore Backup ==="
  echo

  local backup_dir="/root/matrix-backups"
  if [[ ! -d "${backup_dir}" ]]; then
    echo "❌ Backup directory not found: ${backup_dir}"
    pause
    return 1
  fi

  echo "Available backups:"
  ls -1 "${backup_dir}"/*.tar.gz 2>/dev/null || { echo "❌ No backups found."; pause; return 1; }
  echo
  read -rp "Enter full path to backup file: " file

  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "❌ Backup file not found."
    pause
    return 1
  fi

  echo "⚠️  This will overwrite current config/files."
  read -rp "Are you sure you want to restore? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  echo "Stopping services..."
  systemctl stop matrix-synapse || true
  systemctl stop coturn || true
  systemctl stop nginx || true

  echo "Extracting backup..."
  tar -xzf "${file}" -C /

  echo "Testing nginx config..."
  nginx -t || true

  echo "Starting services..."
  systemctl start nginx || true
  systemctl restart coturn || true
  systemctl restart matrix-synapse || true

  echo "✅ Restore complete."
  pause
}

#############################################
# Update Element Web
#############################################

update_element_web() {
  print_header
  echo "⬆️  === Update Element Web ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. You can still update Element files."
  fi

  ensure_pkg jq
  ensure_pkg curl
  ensure_pkg wget

  echo "Choose Element version:"
  echo "1) Enter version manually (recommended)"
  echo "2) Use latest (GitHub API)"
  echo "3) Back"
  read -rp "Choose [1-3]: " opt

  local ver=""
  case "${opt}" in
    1)
      read -rp "Enter version (example: 1.12.7): " ver
      ;;
    2)
      echo "Fetching latest version..."
      local tag
      tag="$(curl -4 -fsS https://api.github.com/repos/element-hq/element-web/releases/latest | jq -r '.tag_name')"
      if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        echo "❌ Could not fetch latest version."
        pause
        return 1
      fi
      ver="${tag#v}"
      echo "Latest: ${ver}"
      ;;
    3) return 0 ;;
    *) echo "Invalid option."; pause; return 1 ;;
  esac

  if [[ -z "${ver}" ]]; then
    echo "❌ Version is required."
    pause
    return 1
  fi

  local url="https://github.com/element-hq/element-web/releases/download/v${ver}/element-v${ver}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  echo "Downloading: ${url}"
  if ! wget -4 -O "${tmp}/element.tar.gz" "${url}"; then
    echo "❌ Download failed. Check version exists or try manual version."
    rm -rf "${tmp}" || true
    pause
    return 1
  fi

  echo "Extracting..."
  tar -xvf "${tmp}/element.tar.gz" -C "${tmp}" >/dev/null

  local extracted="${tmp}/element-v${ver}"
  if [[ ! -d "${extracted}" ]]; then
    echo "❌ Unexpected archive content. Folder not found: ${extracted}"
    rm -rf "${tmp}" || true
    pause
    return 1
  fi

  echo "Preserving existing config.json (if any)..."
  if [[ -f /var/www/element/config.json ]]; then
    cp /var/www/element/config.json "${tmp}/config.json.backup"
  fi

  echo "Replacing /var/www/element..."
  rm -rf /var/www/element
  mv "${extracted}" /var/www/element

  if [[ -f "${tmp}/config.json.backup" ]]; then
    mv "${tmp}/config.json.backup" /var/www/element/config.json
  fi

  rm -rf "${tmp}" || true

  systemctl reload nginx || true
  echo "✅ Element updated to v${ver}."
  pause
}

#############################################
# Full Uninstall / Purge
#############################################

full_uninstall() {
  print_header
  echo "🧨 === FULL UNINSTALL / DEEP PURGE ==="
  echo
  echo "This will COMPLETELY REMOVE all traces:"
  echo " • Matrix Synapse (packages, configs, data, database)"
  echo " • PostgreSQL databases (synapse, mas) and users"
  echo " • Nginx virtual hosts (matrix, element, livekit, mas, wellknown)"
  echo " • coturn (package, config)"
  echo " • LiveKit Server + lk-jwt-service (binaries, configs, systemd)"
  echo " • MAS - Matrix Authentication Service (binary, configs, systemd)"
  echo " • Element Web files"
  echo " • Matrix APT repository and keyring"
  echo " • Install log file"
  echo " • Config file (${CONFIG_FILE})"
  echo
  echo -e "${RED}⚠️  THIS IS DESTRUCTIVE AND IRREVERSIBLE.${NC}"
  echo
  read -rp "Type DELETE to continue: " confirm
  if [[ "${confirm}" != "DELETE" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  # Load config for actual database names
  local ACTUAL_PG_USER="synapse_user"
  local ACTUAL_PG_DB="synapse"
  local ACTUAL_MAS_PG_USER="mas_user"
  local ACTUAL_MAS_PG_DB="mas"
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    ACTUAL_PG_USER="${PG_USER:-synapse_user}"
    ACTUAL_PG_DB="${PG_DB:-synapse}"
    ACTUAL_MAS_PG_USER="${MAS_PG_USER:-mas_user}"
    ACTUAL_MAS_PG_DB="${MAS_PG_DB:-mas}"
  fi

  echo
  log_step "[1/10] Stopping all services..."
  for svc in mas lk-jwt-service livekit-server matrix-synapse coturn nginx; do
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done
  log_info "Services stopped."

  log_step "[2/10] Dropping PostgreSQL databases and users..."
  if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
    # Drop databases
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${ACTUAL_PG_DB};" 2>/dev/null || true
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${ACTUAL_MAS_PG_DB};" 2>/dev/null || true
    # Drop users
    sudo -u postgres psql -c "DROP USER IF EXISTS ${ACTUAL_PG_USER};" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS ${ACTUAL_MAS_PG_USER};" 2>/dev/null || true
    log_info "PostgreSQL databases and users dropped."
  else
    log_warn "PostgreSQL not running or not installed, skipping DB cleanup."
  fi

  log_step "[3/10] Removing packages..."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    matrix-synapse-py3 \
    coturn \
    nginx nginx-common nginx-core \
    certbot python3-certbot-nginx \
    2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
  log_info "Packages removed."

  log_step "[4/10] Removing systemd service files..."
  rm -f /etc/systemd/system/livekit-server.service || true
  rm -f /etc/systemd/system/lk-jwt-service.service || true
  rm -f /etc/systemd/system/mas.service || true
  systemctl daemon-reload
  log_info "Systemd service files removed."

  log_step "[5/10] Removing config files and directories..."
  # Matrix Synapse
  rm -rf /etc/matrix-synapse || true
  rm -rf /var/lib/matrix-synapse || true
  # coturn
  rm -f /etc/turnserver.conf || true
  rm -f /etc/default/coturn || true
  # LiveKit
  rm -rf /etc/livekit || true
  # MAS
  rm -rf /etc/mas || true
  rm -rf /opt/mas || true
  # Element Web
  rm -rf /var/www/element || true
  # Nginx virtual hosts
  rm -f /etc/nginx/sites-available/matrix.conf || true
  rm -f /etc/nginx/sites-available/element.conf || true
  rm -f /etc/nginx/sites-available/wellknown.conf || true
  rm -f /etc/nginx/sites-available/livekit.conf || true
  rm -f /etc/nginx/sites-available/mas-auth.conf || true
  rm -f /etc/nginx/sites-enabled/matrix.conf || true
  rm -f /etc/nginx/sites-enabled/element.conf || true
  rm -f /etc/nginx/sites-enabled/wellknown.conf || true
  rm -f /etc/nginx/sites-enabled/livekit.conf || true
  rm -f /etc/nginx/sites-enabled/mas-auth.conf || true
  log_info "Config files removed."

  log_step "[6/10] Removing binaries..."
  rm -f /usr/local/bin/livekit-server || true
  rm -f /usr/local/bin/lk-jwt-service || true
  rm -f /usr/local/bin/mas-cli || true
  log_info "Binaries removed."

  log_step "[7/10] Removing Matrix APT repository and keyring..."
  rm -f /etc/apt/sources.list.d/matrix-org.list || true
  rm -f /usr/share/keyrings/matrix-org-archive-keyring.gpg || true
  apt-get update 2>/dev/null || true
  log_info "APT repository cleaned."

  log_step "[8/10] Removing log and config files..."
  rm -f "${LOG_FILE}" || true
  rm -f "${CONFIG_FILE}" || true
  log_info "Log and config files removed."

  # --- Optional cleanup prompts ---
  echo
  echo "📌 Optional cleanup:"
  echo

  echo "1️⃣  Remove Let's Encrypt certificates? (/etc/letsencrypt)"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "  Choose [1-2]: " opt_cert
  if [[ "${opt_cert}" == "1" ]]; then
    rm -rf /etc/letsencrypt || true
    # Remove certbot timer if it exists
    systemctl stop certbot.timer 2>/dev/null || true
    systemctl disable certbot.timer 2>/dev/null || true
    log_info "Let's Encrypt certificates removed."
  fi

  echo
  echo "2️⃣  Remove PostgreSQL entirely? (all databases, configs, data)"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "  Choose [1-2]: " opt_pg
  if [[ "${opt_pg}" == "1" ]]; then
    systemctl stop postgresql 2>/dev/null || true
    systemctl disable postgresql 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'postgresql*' 2>/dev/null || true
    rm -rf /var/lib/postgresql || true
    rm -rf /etc/postgresql || true
    rm -rf /var/log/postgresql || true
    rm -rf /run/postgresql || true
    # Remove postgres system user
    userdel -r postgres 2>/dev/null || true
    groupdel postgres 2>/dev/null || true
    log_info "PostgreSQL completely removed."
  fi

  echo
  echo "3️⃣  Remove backup directory? (/root/matrix-backups)"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "  Choose [1-2]: " opt_bak
  if [[ "${opt_bak}" == "1" ]]; then
    rm -rf /root/matrix-backups || true
    log_info "Backup directory removed."
  fi

  log_step "[9/10] Removing UFW rules (if applicable)..."
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow 80/tcp 2>/dev/null || true
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 3478/udp 2>/dev/null || true
    ufw delete allow 3478/tcp 2>/dev/null || true
    ufw delete allow 5349/tcp 2>/dev/null || true
    ufw delete allow 49160:49200/udp 2>/dev/null || true
    ufw delete allow 7881/tcp 2>/dev/null || true
    ufw delete allow 50100:50200/udp 2>/dev/null || true
    log_info "UFW rules removed."
  fi

  log_step "[10/10] Final cleanup..."
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
  apt-get autoclean 2>/dev/null || true
  systemctl daemon-reload
  log_info "System cleaned."

  echo
  echo "======================================================="
  echo -e "${GREEN}✅ DEEP UNINSTALL COMPLETE${NC}"
  echo "======================================================="
  echo
  echo "All Matrix stack traces have been removed from this server."
  echo "Verify with:"
  echo "  ls /etc/matrix-synapse /etc/livekit /etc/mas /opt/mas /var/www/element 2>&1"
  echo "  dpkg -l | grep -E 'matrix-synapse|coturn'"
  echo "  systemctl list-units | grep -E 'matrix|livekit|mas|coturn'"
  echo
  pause
}

#############################################
# Main menu
#############################################

main_menu() {
  while true; do
    print_header
    echo "======= Matrix Stack Manager (PostgreSQL + LiveKit + MAS) ======="
    echo "1)  🧩 Install / Reinstall (Full Stack)"
    echo "2)  👑 Create admin user (interactive)"
    echo "3)  👤 Create normal user (interactive)"
    echo "4)  🎲 Create user with RANDOM password (auto)"
    echo "5)  ♻️ Reactivate user (exists-ok)"
    echo "6)  📋 List users (PostgreSQL)"
    echo "7)  🚫 Deactivate user (safe)"
    echo "8)  📦 Set upload limits (Nginx + Synapse)"
    echo "9)  🧾 Toggle registration ON/OFF"
    echo "10) 🔎 Health Check (all services)"
    echo "11) 🧰 Fix Wizard (auto-fix common issues)"
    echo "12) 💾 Backup server (config + PostgreSQL)"
    echo "13) ♻️ Restore backup"
    echo "14) 📞 Call Diagnostics (TURN/LiveKit/WebRTC)"
    echo "15) ⬆️  Update Element Web"
    echo "16) 📊 Show Database & Credentials Info"
    echo "17) 🧨 Full uninstall / purge"
    echo "18) 🚪 Exit"
    echo "================================================================"
    read -rp "Choose an option [1-18]: " CHOICE

    case "${CHOICE}" in
      1)  install_stack ;;
      2)  create_admin_user ;;
      3)  create_normal_user ;;
      4)  create_user_random_password ;;
      5)  reactivate_user ;;
      6)  list_users ;;
      7)  deactivate_user ;;
      8)  set_upload_limits ;;
      9)  toggle_registration ;;
      10) health_check ;;
      11) fix_wizard ;;
      12) backup_server ;;
      13) restore_backup ;;
      14) call_diagnostics ;;
      15) update_element_web ;;
      16) show_db_info ;;
      17) full_uninstall ;;
      18) echo "Bye."; exit 0 ;;
      *)  echo "Invalid option."; sleep 1 ;;
    esac
  done
}

require_root
main_menu
