#!/bin/bash

#==============================================================================
# IoT Sensor Logger - Complete Bootstrap Script v3.2
# Full Installation + Configuration + Auto Password Generation
#
# Usage: curl -fsSL https://raw.githubusercontent.com/algizzz/iot-sensor-logger/main/bootstrap.sh | sudo bash
# Or:    chmod +x bootstrap.sh && sudo ./bootstrap.sh
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Configuration
readonly REPO_URL="https://github.com/algizzz/iot-sensor-logger.git"
readonly REPO_NAME="iot-sensor-logger"
readonly INSTALL_DIR="/opt/${REPO_NAME}"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly LOG_FILE="/tmp/bootstrap-${TIMESTAMP}.log"

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#==============================================================================
# LOGGING FUNCTIONS
#==============================================================================

log_info() { echo -e "${BLUE}[ℹ]${NC} $*" | tee -a "${LOG_FILE}"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*" | tee -a "${LOG_FILE}"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[✗]${NC} $*" | tee -a "${LOG_FILE}"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════${NC}\n${BLUE}$*${NC}\n${BLUE}════════════════════════════════════════${NC}\n" | tee -a "${LOG_FILE}"; }

#==============================================================================
# UTILITY FUNCTIONS
#==============================================================================

# Generate cryptographically secure random password
generate_password() {
    local length="${1:-32}"
    # Use openssl for CSPRNG (Cryptographically Secure Pseudo-Random Number Generator)
    openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-"${length}"
}

# Generate secure token (base64)
generate_token() {
    local length="${1:-64}"
    openssl rand -base64 96 | tr -d '=+/\n' | cut -c1-"${length}"
}

# Detect public IP address
detect_public_ip() {
    local ip=""
    
    # Try multiple IP detection services
    ip=$(curl -s --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null) && echo "${ip}" && return
    ip=$(curl -s --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null) && echo "${ip}" && return
    ip=$(curl -s --max-time 3 --connect-timeout 2 ipinfo.io/ip 2>/dev/null) && echo "${ip}" && return
    
    # Fallback to local hostname
    hostname -I | awk '{print $1}'
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

#==============================================================================
# PREREQUISITE CHECKS & INSTALLATION
#==============================================================================

check_root() {
    log_info "Checking permissions..."
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
    log_success "Running as root"
}

install_git() {
    log_info "=== [1/5] Checking Git ==="
    
    if command -v git &> /dev/null; then
        log_success "Git already installed ($(git --version | awk '{print $3}'))"
        return 0
    fi
    
    log_info "Installing Git..."
    apt-get update -qq 2>&1 | tail -5 >> "${LOG_FILE}"
    apt-get install -y -qq git curl 2>&1 | tail -5 >> "${LOG_FILE}"
    
    log_success "Git installed ($(git --version | awk '{print $3}'))"
}

install_docker() {
    log_info "=== [2/5] Checking Docker ==="
    
    if command -v docker &> /dev/null; then
        log_success "Docker already installed ($(docker --version | awk '{print $3}' | tr -d ','))"
        
        # Ensure docker is running
        systemctl is-active --quiet docker || { systemctl start docker; log_info "Docker started"; }
        return 0
    fi
    
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>&1 | tee -a "${LOG_FILE}"
    sh /tmp/get-docker.sh 2>&1 | tail -10 >> "${LOG_FILE}"
    rm -f /tmp/get-docker.sh
    
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker installed ($(docker --version | awk '{print $3}' | tr -d ','))"
}

install_docker_compose() {
    log_info "=== [3/5] Checking Docker Compose ==="
    
    if docker compose version &> /dev/null; then
        log_success "Docker Compose already installed ($(docker compose version --short))"
        return 0
    fi
    
    log_info "Installing Docker Compose plugin..."
    apt-get update -qq 2>&1 | tail -3 >> "${LOG_FILE}"
    
    if apt-get install -y -qq docker-compose-plugin 2>&1 | tail -5 >> "${LOG_FILE}"; then
        log_success "Docker Compose installed via apt"
    else
        log_warning "apt installation failed, installing manually..."
        
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL "https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose 2>&1 | tee -a "${LOG_FILE}"
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
    
    log_success "Docker Compose ready ($(docker compose version --short))"
}

clone_or_update_repo() {
    log_info "=== [4/5] Repository Setup ==="
    
    if [ -d "${INSTALL_DIR}" ]; then
        log_warning "Installation found at ${INSTALL_DIR}"
        
        cd "${INSTALL_DIR}"
        log_info "Pulling latest changes..."
        git pull origin main 2>&1 | tail -10 >> "${LOG_FILE}" || \
        git pull origin master 2>&1 | tail -10 >> "${LOG_FILE}" || \
        log_warning "Could not pull updates"
        
        log_success "Repository updated"
        return 0
    fi
    
    log_info "Cloning repository..."
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    git clone "${REPO_URL}" "${INSTALL_DIR}" 2>&1 | tail -5 >> "${LOG_FILE}"
    
    cd "${INSTALL_DIR}"
    log_success "Repository cloned to ${INSTALL_DIR}"
}

#==============================================================================
# AUTO CONFIGURATION WITH PASSWORD GENERATION
#==============================================================================

generate_configuration() {
    log_section "PHASE 2: Auto-Configuration (Generating Secure Credentials)"
    
    cd "${INSTALL_DIR}"
    
    # Check for existing .env
    if [ -f .env ]; then
        log_warning ".env file already exists"
        read -p "Regenerate credentials? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_success "Using existing .env"
            return 0
        fi
    fi
    
    # Detect public IP
    log_info "Detecting public IP address..."
    local public_ip
    public_ip=$(detect_public_ip)
    
    if ! validate_ip "${public_ip}"; then
        log_warning "Could not detect valid public IP (got: ${public_ip})"
        read -p "Enter public IP address: " public_ip
        while ! validate_ip "${public_ip}"; do
            log_error "Invalid IP format"
            read -p "Enter public IP address: " public_ip
        done
    fi
    log_success "Public IP: ${public_ip}"
    
    # Generate all credentials
    log_info "Generating secure credentials..."
    local influx_password=$(generate_password 24)
    local influx_token=$(generate_token 64)
    local mqtt_pass=$(generate_password 24)
    local sensor_pass=$(generate_password 24)
    local api_token=$(generate_token 64)
    
    log_success "Generated all credentials"
    
    # Create .env file
    log_info "Creating .env configuration..."
    cat > .env <<EOF
# ========================================
# IoT Sensor Logger Configuration
# Auto-generated: $(date)
# ========================================

# Server Configuration
PUBLIC_IP=${public_ip}
API_PORT=8000

# ========================================
# InfluxDB 2 Configuration
# ========================================
DOCKER_INFLUXDB_INIT_MODE=setup
DOCKER_INFLUXDB_INIT_USERNAME=admin
DOCKER_INFLUXDB_INIT_PASSWORD=${influx_password}
DOCKER_INFLUXDB_INIT_ORG=iot
DOCKER_INFLUXDB_INIT_BUCKET=iotsensors
DOCKER_INFLUXDB_INIT_RETENTION=168h
DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${influx_token}

# InfluxDB Connection (for services)
INFLUX_URL=http://influxdb:8086
INFLUX_ORG=iot
INFLUX_BUCKET=iotsensors
INFLUX_TOKEN=${influx_token}

# ========================================
# MQTT Configuration (Mosquitto)
# ========================================

# Telegraf user credentials
MQTTUSER=telegraf
MQTTPASS=${mqtt_pass}

# IoT Sensor user credentials
SENSORUSER=sensor
SENSORPASS=${sensor_pass}

# ========================================
# API Configuration
# ========================================
API_TOKEN=${api_token}
EOF

    chmod 600 .env
    log_success ".env file created (permissions: 600)"
    
    # Save credentials to backup file
    log_info "Saving credentials backup..."
    cat > CREDENTIALS.txt <<EOFCREDS
╔═══════════════════════════════════════════════════════════════╗
║     IoT Sensor Logger - Generated Credentials & Settings     ║
║                Generated: $(date)                        ║
╚═══════════════════════════════════════════════════════════════╝

📍 SERVICE URLs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  🔹 InfluxDB UI:    http://${public_ip}:8086
  🔹 API Docs:       http://${public_ip}:8000/docs
  🔹 API Redoc:      http://${public_ip}:8000/redoc
  🔹 MQTT Broker:    mqtt://${public_ip}:1883

🔐 CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  📊 InfluxDB
    • Username:      admin
    • Password:      ${influx_password}
    • Token:         ${influx_token}
    • Organization:  iot
    • Bucket:        iotsensors
    • Retention:     7 days (168h)

  🔌 MQTT Broker (Telegraf)
    • Username:      telegraf
    • Password:      ${mqtt_pass}
    • Port:          1883

  📱 MQTT Broker (IoT Sensors)
    • Username:      sensor
    • Password:      ${sensor_pass}
    • Port:          1883

  🔑 API Authentication
    • Token:         ${api_token}
    • Type:          Bearer Token
    • Use in header: Authorization: Bearer ${api_token}

🛠️ MANAGEMENT COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  cd ${INSTALL_DIR}

  # View container status
  docker compose ps

  # View logs
  docker compose logs -f [service_name]

  # Restart services
  docker compose restart [service_name]

  # Stop all services
  docker compose down

  # Start services
  docker compose up -d

📋 IMPORTANT NOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ⚠️  KEEP THIS FILE SECURE - Contains sensitive credentials
  📁 Configuration: ${INSTALL_DIR}/.env
  📝 Log file:      ${LOG_FILE}

  Default retention for sensor data: 7 days
  Available services: InfluxDB, Telegraf, Mosquitto, FastAPI

╔═══════════════════════════════════════════════════════════════╗
║  For support and documentation, visit the repository:         ║
║  https://github.com/algizzz/iot-sensor-logger                ║
╚═══════════════════════════════════════════════════════════════╝
EOFCREDS

    chmod 600 CREDENTIALS.txt
    log_success "Credentials saved to CREDENTIALS.txt"
    
    # Display summary
    echo ""
    cat CREDENTIALS.txt
    echo ""
}

#==============================================================================
# DEPLOYMENT
#==============================================================================

run_deployment() {
    log_section "PHASE 3: Deployment (Starting Services)"
    
    cd "${INSTALL_DIR}"
    
    if [ ! -f deploy.sh ]; then
        log_error "deploy.sh not found in ${INSTALL_DIR}"
        exit 1
    fi
    
    chmod +x deploy.sh
    
    log_info "Running deployment script..."
    echo ""
    
    if ./deploy.sh; then
        log_success "Deployment completed successfully"
        return 0
    else
        log_error "Deployment failed - check logs above"
        return 1
    fi
}

#==============================================================================
# FINAL SUMMARY
#==============================================================================

print_summary() {
    echo ""
    log_section "✓ Bootstrap Completed Successfully!"
    
    cat <<EOF

📍 Installation Details:
   • Location:      ${INSTALL_DIR}
   • Configuration: ${INSTALL_DIR}/.env
   • Credentials:   ${INSTALL_DIR}/CREDENTIALS.txt
   • Log file:      ${LOG_FILE}

🚀 Next Steps:

   1. View your credentials:
      cat ${INSTALL_DIR}/CREDENTIALS.txt

   2. Access services:
      • InfluxDB UI: Open in browser with credentials from above
      • API Docs: /docs endpoint
      • MQTT: Use telegraf/sensor users from above

   3. Monitor services:
      cd ${INSTALL_DIR}
      docker compose logs -f

   4. To stop all services:
      docker compose down

📞 Support & Documentation:
   https://github.com/algizzz/iot-sensor-logger

EOF
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================

trap 'log_error "Bootstrap failed on line $LINENO" && exit 1' ERR

main() {
    # Initialize log file
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
    
    # Header
    log_section "IoT Sensor Logger - Bootstrap & Deployment (v3.2)"
    
    log_info "Log file: ${LOG_FILE}"
    
    # Phase 1: Installation
    log_section "PHASE 1: Installing Prerequisites"
    
    check_root
    install_git
    install_docker
    install_docker_compose
    clone_or_update_repo
    
    # Phase 2: Configuration
    generate_configuration
    
    # Phase 3: Deployment
    run_deployment
    
    # Summary
    print_summary
    
    log_success "Bootstrap process completed at $(date)"
}

# Execute main
main "$@"

