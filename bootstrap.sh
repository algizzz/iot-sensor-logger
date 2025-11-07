#!/bin/bash

#==============================================================================
# IoT Sensor Logger - One-Command Bootstrap & Deployment Script
# Version: 3.0
# 
# Usage: 
#   curl -fsSL https://raw.githubusercontent.com/algizzz/iot-sensor-logger/main/bootstrap.sh | sudo bash
#
# Or manually:
#   wget https://raw.githubusercontent.com/algizzz/iot-sensor-logger/main/bootstrap.sh
#   chmod +x bootstrap.sh
#   sudo ./bootstrap.sh
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Repository configuration
readonly REPO_URL="https://github.com/algizzz/iot-sensor-logger.git"
readonly REPO_NAME="iot-sensor-logger"
readonly INSTALL_DIR="/opt/${REPO_NAME}"

# Logging
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

#==============================================================================
# PHASE 1: PREREQUISITES
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
    log_info "=== [1/4] Installing Git ==="
    
    if command -v git &> /dev/null; then
        log_success "Git already installed ($(git --version | cut -d' ' -f3))"
        return 0
    fi
    
    log_info "Installing Git..."
    apt-get update -qq
    apt-get install -y -qq git
    
    if ! command -v git &> /dev/null; then
        log_error "Git installation failed"
        exit 1
    fi
    
    log_success "Git installed successfully ($(git --version | cut -d' ' -f3))"
}

install_docker() {
    log_info "=== [2/4] Installing Docker ==="
    
    if command -v docker &> /dev/null; then
        log_success "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
        return 0
    fi
    
    log_info "Downloading Docker installation script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    
    log_info "Installing Docker..."
    sh /tmp/get-docker.sh
    
    # Clean up
    rm -f /tmp/get-docker.sh
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker installation failed"
        exit 1
    fi
    
    log_success "Docker installed successfully ($(docker --version | cut -d' ' -f3 | tr -d ','))"
}

install_docker_compose() {
    log_info "=== [3/4] Installing Docker Compose Plugin ==="
    
    if docker compose version &> /dev/null; then
        log_success "Docker Compose already installed ($(docker compose version --short))"
        return 0
    fi
    
    log_info "Installing Docker Compose plugin..."
    
    # Docker Compose обычно устанавливается с Docker, но проверим
    apt-get update -qq
    apt-get install -y -qq docker-compose-plugin 2>/dev/null || {
        log_warning "docker-compose-plugin not in repo, installing manually..."
        
        # Manual installation
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL "https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    }
    
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose installation failed"
        exit 1
    fi
    
    log_success "Docker Compose installed ($(docker compose version --short))"
}

clone_repository() {
    log_info "=== [4/4] Cloning Repository ==="
    
    # Remove old installation if exists
    if [ -d "${INSTALL_DIR}" ]; then
        log_warning "Existing installation found at ${INSTALL_DIR}"
        read -p "Remove and reinstall? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Removing old installation..."
            rm -rf "${INSTALL_DIR}"
        else
            log_info "Using existing installation"
            cd "${INSTALL_DIR}"
            log_info "Pulling latest changes..."
            git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || log_warning "Could not pull updates"
            log_success "Repository updated"
            return 0
        fi
    fi
    
    log_info "Cloning repository from ${REPO_URL}..."
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    
    if [ ! -d "${INSTALL_DIR}" ]; then
        log_error "Repository clone failed"
        exit 1
    fi
    
    cd "${INSTALL_DIR}"
    log_success "Repository cloned to ${INSTALL_DIR}"
}

#==============================================================================
# PHASE 2: CONFIGURATION
#==============================================================================

setup_environment() {
    log_info "=== Setting up environment ==="
    
    cd "${INSTALL_DIR}"
    
    # Check if .env exists
    if [ -f .env ]; then
        log_info ".env file already exists"
        read -p "Reconfigure? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_success "Using existing .env"
            return 0
        fi
    fi
    
    # Check for .env.example
    if [ ! -f .env.example ]; then
        log_error ".env.example not found in repository"
        log_info "Please create .env manually and run: cd ${INSTALL_DIR} && ./deploy.sh"
        exit 1
    fi
    
    # Copy .env.example to .env
    log_info "Creating .env from .env.example..."
    cp .env.example .env
    
    log_warning "Please edit .env file with your configuration:"
    log_info "  nano ${INSTALL_DIR}/.env"
    log_info ""
    log_info "Required variables:"
    log_info "  - PUBLIC_IP (your server IP)"
    log_info "  - MQTTUSER, MQTTPASS (MQTT credentials)"
    log_info "  - DOCKER_INFLUXDB_INIT_* (InfluxDB settings)"
    log_info "  - API_TOKEN (API authentication token)"
    echo ""
    
    read -p "Press Enter when ready to continue with deployment..."
}

#==============================================================================
# PHASE 3: DEPLOYMENT
#==============================================================================

run_deployment() {
    log_info "=== Starting Deployment ==="
    
    cd "${INSTALL_DIR}"
    
    # Check if deploy.sh exists
    if [ ! -f deploy.sh ]; then
        log_error "deploy.sh not found in repository"
        exit 1
    fi
    
    # Make executable
    chmod +x deploy.sh
    
    log_info "Running deployment script..."
    echo ""
    echo "========================================"
    echo ""
    
    # Execute deploy.sh
    ./deploy.sh
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    echo ""
    log_info "======================================================"
    log_info "  IoT Sensor Logger - Bootstrap & Deployment"
    log_info "======================================================"
    echo ""
    
    check_root
    
    echo ""
    log_info "PHASE 1: Installing Prerequisites"
    echo ""
    
    install_git
    install_docker
    install_docker_compose
    clone_repository
    
    echo ""
    log_info "PHASE 2: Configuration"
    echo ""
    
    setup_environment
    
    echo ""
    log_info "PHASE 3: Deployment"
    echo ""
    
    run_deployment
    
    echo ""
    log_success "======================================================"
    log_success "  Bootstrap completed successfully!"
    log_success "======================================================"
    echo ""
    log_info "Installation directory: ${INSTALL_DIR}"
    log_info "To manage services:"
    log_info "  cd ${INSTALL_DIR}"
    log_info "  docker compose ps"
    log_info "  docker compose logs -f"
    echo ""
}

# Trap errors
trap 'log_error "Script failed on line $LINENO. Check logs above."' ERR

main "$@"

