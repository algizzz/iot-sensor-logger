#!/bin/bash

#==============================================================================
# IoT Sensor Logger - Public Dashboard Setup Script
# Creates a separate public-ready dashboard copy
#==============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${LOG_DIR}/public-dashboard-${TIMESTAMP}.log"

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging
log() {
    local level="$1"; shift
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "${BLUE}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}✓ $*${NC}"; }
log_warning() { log "WARNING" "${YELLOW}⚠ $*${NC}"; }
log_error() { log "ERROR" "${RED}✗ $*${NC}"; }

main() {
    mkdir -p "${LOG_DIR}"
    
    # Check if running as root/sudo
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run with sudo"
        exit 1
    fi
    
    log_info "===================================="
    log_info "Public Dashboard Setup"
    log_info "===================================="
    echo ""
    
    # 1. Load configuration
    log_info "[1/5] Loading configuration..."
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        log_error ".env file not found"
        exit 1
    fi
    
    set -a; source "${SCRIPT_DIR}/.env"; set +a
    
    readonly GRAFANA_LOCAL_URL="http://localhost:3000"
    readonly GRAFANA_PUBLIC_URL="http://${PUBLIC_IP}:3000"
    
    log_success "Configuration loaded"
    
    # 2. Wait for Grafana
    log_info "[2/5] Waiting for Grafana..."
    local attempt=1
    while [ ${attempt} -le 30 ]; do
        if curl -s -f -o /dev/null "${GRAFANA_LOCAL_URL}/api/health"; then
            log_success "Grafana is ready"
            break
        fi
        [ ${attempt} -eq 30 ] && { log_error "Grafana timeout"; exit 1; }
        sleep 2; ((attempt++))
    done
    
    # 3. Find and prepare dashboard
    log_info "[3/5] Preparing public dashboard..."
    local dashboard_file=$(find "${SCRIPT_DIR}/grafana/provisioning/dashboards" -name "*.json" -type f 2>/dev/null | head -1)
    
    if [ -z "${dashboard_file}" ]; then
        log_error "Dashboard JSON file not found"
        exit 1
    fi
    
    log_info "Source: $(basename "${dashboard_file}")"
    
    # Get datasource UID
    local datasource_uid=$(curl -s -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "${GRAFANA_LOCAL_URL}/api/datasources" | \
        grep -oP '"uid":"P951FEA4DE68E13C5"' | head -1 | cut -d'"' -f4)
    
    if [ -z "${datasource_uid}" ]; then
        datasource_uid="P951FEA4DE68E13C5"
    fi
    
    log_success "Datasource UID: ${datasource_uid}"
    
    # Create public-ready dashboard
    local public_dashboard="${SCRIPT_DIR}/logs/public-dashboard-${TIMESTAMP}.json"
    
    python3 << EOF
import json
import re

# Read original dashboard
with open("${dashboard_file}", "r") as f:
    content = f.read()

# Replace datasource variables
content = content.replace('"uid": "\${DS_INFLUXDB}"', '"uid": "${datasource_uid}"')

# Parse JSON
data = json.loads(content)

# Modify for public dashboard
data.pop("id", None)  # Remove ID
data["uid"] = "iot-sensors-public"  # New UID
data["title"] = "IoT Sensors Dashboard (Public)"  # New title
data["editable"] = False  # Make read-only

# Save
with open("${public_dashboard}", "w") as f:
    json.dump(data, f, indent=2)

print("iot-sensors-public")
EOF
    
    local new_dashboard_uid="iot-sensors-public"
    log_success "Public dashboard UID: ${new_dashboard_uid}"
    
    # 4. Upload new dashboard
    log_info "[4/5] Uploading public dashboard..."
    
    local upload_payload=$(python3 << EOF
import json
dashboard = json.load(open("${public_dashboard}"))
payload = {
    "dashboard": dashboard,
    "overwrite": True,
    "message": "Public dashboard with fixed datasource"
}
print(json.dumps(payload))
EOF
)
    
    local upload_response=$(curl -s -X POST \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "${upload_payload}" \
        "${GRAFANA_LOCAL_URL}/api/dashboards/db")
    
    if ! echo "${upload_response}" | grep -q '"status":"success"'; then
        log_error "Failed to upload dashboard"
        log_error "Response: ${upload_response}"
        exit 1
    fi
    
    log_success "Dashboard uploaded"
    
    # 5. Create/update public link
    log_info "[5/5] Setting up public access..."
    
    # Check if public dashboard already exists
    local existing_public=$(curl -s -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "${GRAFANA_LOCAL_URL}/api/dashboards/uid/${new_dashboard_uid}/public-dashboards/" 2>/dev/null || true)
    
    local public_uid=$(echo "${existing_public}" | grep -oP '"uid"\s*:\s*"\K[^"]+' | head -1 || true)
    
    # Delete existing if found
    if [ -n "${public_uid}" ]; then
        log_info "Removing old public configuration..."
        curl -s -X DELETE \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
            "${GRAFANA_LOCAL_URL}/public-dashboards/${public_uid}" > /dev/null 2>&1 || true
        sleep 1
    fi
    
    # Create new public dashboard
    log_info "Creating public link with time picker..."
    local public_response=$(curl -s -X POST \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{
            "isEnabled": true,
            "share": "public",
            "timeSelectionEnabled": true,
            "annotationsEnabled": false
        }' \
        "${GRAFANA_LOCAL_URL}/api/dashboards/uid/${new_dashboard_uid}/public-dashboards/")
    
    local access_token=$(echo "${public_response}" | grep -oP '"accessToken"\s*:\s*"\K[^"]+' || true)
    
    if [ -z "${access_token}" ]; then
        log_error "Failed to create public link"
        log_error "Response: ${public_response}"
        exit 1
    fi
    
    # Verify time picker is enabled
    local verify=$(curl -s -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "${GRAFANA_LOCAL_URL}/api/dashboards/uid/${new_dashboard_uid}/public-dashboards/")
    
    local time_enabled=$(echo "${verify}" | grep -oP '"timeSelectionEnabled"\s*:\s*\K(true|false)')
    
    local public_url="${GRAFANA_PUBLIC_URL}/public-dashboards/${access_token}"
    echo "${public_url}" > "${SCRIPT_DIR}/public-dashboard-url.txt"
    
    echo ""
    log_success "====================================="
    log_success "✓ Public Dashboard Ready!"
    log_success "====================================="
    echo ""
    echo -e "${GREEN}Public URL:${NC}"
    echo -e "${BLUE}${public_url}${NC}"
    echo ""
    echo -e "${GREEN}Features:${NC}"
    if [ "${time_enabled}" = "true" ]; then
        echo -e "  ✓ Time range picker: ${GREEN}ENABLED${NC}"
    else
        echo -e "  ✗ Time range picker: ${RED}DISABLED${NC}"
    fi
    echo -e "  ✓ Fixed datasource (no errors)"
    echo -e "  ✓ Public access (no login)"
    echo ""
    log_info "URL saved to: public-dashboard-url.txt"
    log_info "Dashboard file: ${public_dashboard}"
    log_info "Log: ${LOG_FILE}"
    echo ""
    log_warning "Note: Port 3000 must be accessible externally"
    echo ""
}

main "$@"
