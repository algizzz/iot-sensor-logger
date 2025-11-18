#!/bin/bash

# ==============================================================================
# A simple bootstrap script for initial server setup
# ==============================================================================

set -euo pipefail

# --- Configuration ---
readonly REPO_URL="https://github.com/algizzz/iot-sensor-logger.git"
readonly INSTALL_DIR="/opt/iot-sensor-logger"

# --- Log Colors ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Main Functions ---

# Checking for superuser privileges
check_root() {
    log_info "Checking for superuser privileges..."
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Use 'sudo'."
        exit 1
    fi
    log_info "Superuser privileges confirmed."
}

# Waiting for apt lock to be released
wait_for_apt_lock() {
    log_info "Checking for apt locks..."
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        log_warn "apt lock detected. Waiting 10 seconds..."
        sleep 10
    done
    log_info "apt locks released. Continuing."
}

# Installing dependencies (Git, Docker)
install_dependencies() {
    log_info "Checking and installing dependencies..."
    
    wait_for_apt_lock

    # Updating package list once
    log_info "Updating package list..."
    apt-get update >/dev/null

    # Installing Git
    if command -v git &>/dev/null; then
        log_info "Git is already installed."
    else
        log_info "Git not found. Installing..."
        apt-get install -y git
        log_info "Git installed successfully."
    fi

    # Installing Docker
    if command -v docker &>/dev/null; then
        log_info "Docker is already installed."
    else
        log_info "Docker not found. Installing..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        log_info "Docker installed successfully."
    fi

    # Installing Docker Compose
    if docker compose version &>/dev/null; then
        log_info "Docker Compose is already installed."
    else
        log_info "Docker Compose not found. Installing plugin..."
        apt-get install -y docker-compose-plugin
        log_info "Docker Compose plugin installed successfully."
    fi
}

# Cloning repository and starting installation
clone_and_install() {
    log_info "Cloning repository into ${INSTALL_DIR}..."

    if [ -d "${INSTALL_DIR}" ]; then
        log_warn "Directory ${INSTALL_DIR} already exists. Deleting for a fresh installation..."
        rm -rf "${INSTALL_DIR}"
    fi
    
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    log_info "Setting execute permissions for scripts..."
    chmod +x *.sh
    
    log_info "Repository cloned successfully. Running installation scripts..."
    
    log_info "Generating .env file..."
    ./envgen.sh
    
    log_info "Deploying Docker stack..."
    ./deploy.sh
}

# --- Main Execution ---
main() {
    check_root
    install_dependencies
    clone_and_install
    log_info "Bootstrap script and installation completed successfully!"
    log_info "The project is deployed in the ${INSTALL_DIR} directory"
}

# Running main function
main
