#!/bin/bash

#==============================================================================
# IoT Sensor Logger - Public Dashboard Setup Script
# Fixes datasource variables and creates public link
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
    
    log_info "===================================="
    log_info "Public Dashboard Setup with Fix"
    log_info "===================================="
    echo ""
    
    # Load .env
    log_info "[1/5] Loading configuration..."
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        log_error ".env file not found"
        exit 1
    fi
    
    set -a; source "${SCRIPT_DIR}/.env"; set +a
    
    readonly GRAFANA_LOCAL_URL="http://localhost:3000"
    readonly GRAFANA_PUBLIC_URL="http://${PUBLIC_IP}:3000"
    
    log_success "Configuration loaded"
    
    # Wait for Grafana
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
    
    # Find dashboard file
    log_info "[3/5] Finding dashboard file..."
    local dashboard_file=$(find "${SCRIPT_DIR}/grafana/provisioning/dashboards" -name "*.json" -type f 2>/dev/null | head -1)
    
    if [ -z "${dashboard_file}" ]; then
        log_error "Dashboard JSON file not found"
        exit 1
    fi
    
    log_info "Found: $(basename "${dashboard_file}")"
    
    # Get InfluxDB datasource UID from Grafana
    log_info "[4/5] Getting InfluxDB datasource UID..."
    local datasource_uid=$(curl -s -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "${GRAFANA_LOCAL_URL}/api/datasources" | \
        grep -oP '"uid":"P951FEA4DE68E13C5"' | head -1 | cut -d'"' -f4)
    
    if [ -z "${datasource_uid}" ]; then
        log_warning "Could not find datasource, using default: P951FEA4DE68E13C5"
        datasource_uid="P951FEA4DE68E13C5"
    fi
    
    log_success "Datasource UID: ${datasource_uid}"
    
    # Fix dashboard JSON
    log_info "Fixing datasource variables in dashboard..."
    local fixed_dashboard="${SCRIPT_DIR}/logs/dashboard-fixed-${TIMESTAMP}.json"
    
    # Replace ${DS_INFLUXDB} with actual UID
    sed 's/"uid": "${DS_INFLUXDB}"/"uid": "'"${datasource_uid}"'"/g' "${dashboard_file}" > "${fixed_dashboard}"
    
    # Also remove the id field and set a new UID
    python3 << EOF
import json
with open("${fixed_dashboard}", "r") as f:
    data = json.load(f)

# Remove id (Grafana will auto-assign)
data.pop("id", None)

# Set UID for public dashboard
if "uid" not in data or not data["uid"]:
    data["uid"] = "iot-sensors-public"
else:
    data["uid"] = data["uid"] + "-public"

with open("${fixed_dashboard}", "w") as f:
    json.dump(data, f, indent=2)
print(data["uid"])
EOF
    
    local dashboard_uid=$(python3 -c "import json; print(json.load(open('${fixed_dashboard}'))['uid'])")
    
    log_success "Fixed dashboard UID: ${dashboard_uid}"
    
    # Upload dashboard
    log_info "[5/5] Uploading fixed dashboard to Grafana..."
    
    local dashboard_json=$(cat "${fixed_dashboard}")
    local upload_payload=$(python3 << EOF
import json
dashboard = json.load(open("${fixed_dashboard}"))
payload = {
    "dashboard": dashboard,
    "overwrite": True,
    "message": "Fixed datasource for public sharing"
}
print(json.dumps(payload))
EOF
)
    
    local upload_response=$(curl -s -X POST \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "${upload_payload}" \
        "${GRAFANA_LOCAL_URL}/api/dashboards/db")
    
    if echo "${upload_response}" | grep -q '"status":"success"'; then
        log_success "Dashboard uploaded successfully"
    else
        log_error "Failed to upload dashboard"
        log_error "Response: ${upload_response}"
        exit 1
    fi
    
    # Create/get public dashboard link
    log_info "Creating public dashboard link..."
    
    local public_response=$(curl -s -X POST \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{"isEnabled": true, "share": "public"}' \
        "${GRAFANA_LOCAL_URL}/api/dashboards/uid/${dashboard_uid}/public-dashboards/")
    
    local access_token=$(echo "${public_response}" | grep -oP '"accessToken"\s*:\s*"\K[^"]+' || true)
    
    # If already exists, get it
    if [ -z "${access_token}" ]; then
        local existing_response=$(curl -s \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
            "${GRAFANA_LOCAL_URL}/api/dashboards/uid/${dashboard_uid}/public-dashboards/")
        access_token=$(echo "${existing_response}" | grep -oP '"accessToken"\s*:\s*"\K[^"]+' | head -1)
    fi
    
    if [ -z "${access_token}" ]; then
        log_error "Failed to get public dashboard token"
        exit 1
    fi
    
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
    log_info "Saved to: public-dashboard-url.txt"
    log_info "Fixed dashboard: ${fixed_dashboard}"
    echo ""
}

main "$@"
