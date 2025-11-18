#!/bin/bash
# ==============================================================================
# Script for generating .env file with secure credentials
# Uses .env.example as a template.
# ==============================================================================

set -euo pipefail

# --- CONFIGURATION ---
readonly ENV_EXAMPLE=".env.example"
readonly ENV_FILE=".env"

# --- LOG COLORS ---
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# --- LOGGING FUNCTIONS ---
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- DATA GENERATORS ---

# Generates a secure password
generate_password() {
    openssl rand -base64 24
}

# Generates a secure token of a specified length
generate_token() {
    local length="${1:-64}"
    openssl rand -base64 96 | tr -d '=+/\n' | cut -c1-"${length}"
}

# Detects the public IP address of the server
detect_public_ip() {
    local ip
    ip=$(curl -4 -s --max-time 3 ifconfig.me) || \
    ip=$(curl -4 -s --max-time 3 icanhazip.com) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-"127.0.0.1"}"
}


# --- MAIN LOGIC ---
main() {
    log_info "Starting .env file generation..."

    # 1. Checking for .env.example
    if [ ! -f "${ENV_EXAMPLE}" ]; then
        log_error "Template file '${ENV_EXAMPLE}' not found. Place it in the same directory."
        exit 1
    fi

    # 2. Checking if .env exists
    if [ -f "${ENV_FILE}" ]; then
        log_warn "File '${ENV_FILE}' already exists."
        read -p "Are you sure you want to overwrite it? (y/N): " choice
        case "$choice" in
            y|Y ) log_info "The file will be overwritten.";;
            * ) log_info "Operation cancelled."; exit 0;; 
        esac
    fi

    # 3. Generating new values
    log_info "Generating secure credentials..."
    PUBLIC_IP=$(detect_public_ip)
    INFLUXDB_PASS=$(generate_password)
    # In .env.example DOCKER_INFLUXDB_INIT_ADMIN_TOKEN and INFLUXTOKEN use the same template,
    # so we generate one value for them, as intended.
    INFLUXDB_ADMIN_TOKEN=$(generate_token 64)
    TELEGRAF_PASS=$(generate_password)
    SENSOR_PASS=$(generate_password)
    API_TOKEN=$(generate_token 64)
    GRAFANA_ADMIN_USER="admin" # Default Grafana admin user
    GRAFANA_ADMIN_PASSWORD=$(generate_password)

    log_info "Public IP address detected as: ${PUBLIC_IP}"

    # 4. Copying template and replacing values
    log_info "Creating '${ENV_FILE}' from template..."
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"

    # Using sed for reliable replacement of values by key
    sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=${PUBLIC_IP}|" "${ENV_FILE}"
    sed -i "s|^DOCKER_INFLUXDB_INIT_PASSWORD=.*|DOCKER_INFLUXDB_INIT_PASSWORD=${INFLUXDB_PASS}|" "${ENV_FILE}"
    sed -i "s|^DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=.*|DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}|" "${ENV_FILE}"
    sed -i "s|^MQTTPASS=.*|MQTTPASS=${TELEGRAF_PASS}|" "${ENV_FILE}"
    sed -i "s|^SENSORPASS=.*|SENSORPASS=${SENSOR_PASS}|" "${ENV_FILE}"
    sed -i "s|^INFLUXTOKEN=.*|INFLUXTOKEN=${INFLUXDB_ADMIN_TOKEN}|" "${ENV_FILE}"
    sed -i "s|^API_TOKEN=.*|API_TOKEN=${API_TOKEN}|" "${ENV_FILE}"
    sed -i "s|^GRAFANA_ADMIN_USER=.*|GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}|" "${ENV_FILE}"
    sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}|" "${ENV_FILE}"

    # 5. Setting permissions
    chmod 600 "${ENV_FILE}"

    log_info "--------------------------------------------------"
    log_info "File '${ENV_FILE}' has been successfully created and secured."
    log_info "Keep this data in a safe place."
    log_info "--------------------------------------------------"
    
    # Show result without comments
    grep -v '^#' "${ENV_FILE}"
}

# --- RUN SCRIPT ---
main
