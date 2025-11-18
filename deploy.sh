#!/bin/bash

#==============================================================================
# IoT Sensor Logger - Deployment Script
# Version: 3.0
# 
# Can be run standalone or via bootstrap.sh
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Detect script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${LOG_DIR}/deployment-${TIMESTAMP}.log"

readonly BACKUP_DIR="${SCRIPT_DIR}/backups/${TIMESTAMP}"

readonly MAX_RETRY_ATTEMPTS=5
readonly INITIAL_RETRY_DELAY=2
readonly CONTAINER_START_TIMEOUT=120
readonly MIN_DOCKER_COMPOSE_VERSION="2.0.0"

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

mkdir -p "${LOG_DIR}"

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "${BLUE}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}✓ $*${NC}"; }
log_warning() { log "WARNING" "${YELLOW}⚠ $*${NC}"; }
log_error() { log "ERROR" "${RED}✗ $*${NC}"; }

declare -a CLEANUP_ACTIONS=()

register_cleanup() {
    CLEANUP_ACTIONS+=("$1")
}

cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        log_error "Deployment failed with exit code ${exit_code}. Starting rollback..."
        for ((idx=${#CLEANUP_ACTIONS[@]}-1; idx>=0; idx--)); do
            eval "${CLEANUP_ACTIONS[idx]}" || true
        done
        log_warning "Rollback completed. Check logs at: ${LOG_FILE}"
    fi
    exit ${exit_code}
}

trap cleanup EXIT ERR INT TERM

retry_with_backoff() {
    local cmd="$1"
    local max_attempts="${2:-${MAX_RETRY_ATTEMPTS}}"
    local delay="${3:-${INITIAL_RETRY_DELAY}}"
    local max_delay="${4:-60}"
    local attempt=1
    
    while [ ${attempt} -le ${max_attempts} ]; do
        if eval "${cmd}"; then
            [ ${attempt} -gt 1 ] && log_success "Command succeeded after $((attempt-1)) retries"
            return 0
        fi
        
        local exit_code=$?
        [ ${attempt} -eq ${max_attempts} ] && return ${exit_code}
        
        log_warning "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
        sleep ${delay}
        delay=$((delay * 2 + RANDOM % 5))
        [ ${delay} -gt ${max_delay} ] && delay=${max_delay}
        ((attempt++))
    done
}

version_ge() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

validate_prerequisites() {
    log_info "==================================="
    log_info "IoT Sensor Logger - Auto Deployment"
    log_info "==================================="
    echo ""
    
    log_info "[1/7] Validating prerequisites..."
    
    [ "$EUID" -ne 0 ] && { log_error "Must run as root"; exit 1; }
    [ ! -f "${SCRIPT_DIR}/docker-compose.yml" ] && { log_error "docker-compose.yml not found"; exit 1; }
    [ ! -f "${SCRIPT_DIR}/.env" ] && { log_error ".env file not found"; exit 1; }
    
    log_success "Prerequisites validated"
}

validate_env_file() {
    log_info "[2/7] Loading configuration from .env..."
    
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
    
    local required_vars=("MQTTUSER" "MQTTPASS" "DOCKER_INFLUXDB_INIT_USERNAME" 
                        "DOCKER_INFLUXDB_INIT_PASSWORD" "DOCKER_INFLUXDB_INIT_ORG" 
                        "DOCKER_INFLUXDB_INIT_BUCKET" "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" 
                        "API_TOKEN" "PUBLIC_IP")
    
    for var in "${required_vars[@]}"; do
        [ -z "${!var:-}" ] && { log_error "Missing: $var"; exit 1; }
    done
    
    export SENSOR_USER="${SENSORUSER:-sensor}"
    export SENSOR_PASS="${SENSORPASS:-sensorpass}"
    export API_PORT="${APIPORT:-8000}"
    
    log_success "Configuration loaded"
    log_info "  - PUBLIC_IP: ${PUBLIC_IP}"
    log_info "  - MQTT User (Telegraf): ${MQTTUSER}"
    log_info "  - MQTT User (Sensor): ${SENSOR_USER}"
}

check_dependencies() {
    log_info "[3/7] Checking dependencies..."
    
    if ! command -v docker &> /dev/null; then
        log_warning "Docker not found. Installing..."
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>&1 | tee -a "${LOG_FILE}"
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl start docker && systemctl enable docker
        log_success "Docker installed"
    else
        log_success "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
    fi
    
    ! docker compose version &> /dev/null && { log_error "Docker Compose not found"; exit 1; }
    local compose_version=$(docker compose version --short)
    ! version_ge "${compose_version}" "${MIN_DOCKER_COMPOSE_VERSION}" && { log_error "Docker Compose too old"; exit 1; }
    log_success "Docker Compose ${compose_version} compatible"
}

setup_directories() {
    log_info "[4/7] Creating directory structure..."
    
    [ -d "${SCRIPT_DIR}/.mosquitto" ] && {
        mkdir -p "${BACKUP_DIR}"
        cp -r "${SCRIPT_DIR}/.mosquitto" "${BACKUP_DIR}/"
    }
    
    mkdir -p "${SCRIPT_DIR}/.mosquitto"/{config,data,log}
    chmod -R 755 "${SCRIPT_DIR}/.mosquitto"
    
    # CRITICAL: Create password file before starting the container
    touch "${SCRIPT_DIR}/.mosquitto/config/passwd"
    chmod 644 "${SCRIPT_DIR}/.mosquitto/config/passwd"
    
    # Create Grafana data directory
    mkdir -p "${SCRIPT_DIR}/grafana-data"
    chmod 777 "${SCRIPT_DIR}/grafana-data" # Grafana container runs as user 472, needs write access

    # Create Grafana provisioning directories
    mkdir -p "${SCRIPT_DIR}/grafana/provisioning"/{datasources,dashboards}
    chmod -R 755 "${SCRIPT_DIR}/grafana"

    log_success "Directory structure created"
}

configure_firewall() {
    log_info "[5/7] Configuring firewall..."
    
    ! command -v ufw &> /dev/null && { log_warning "UFW not found"; return 0; }
    ! ufw status | grep -q "Status: active" && { log_warning "UFW not active"; return 0; }
    
    local ports=("1883/tcp" "8086/tcp" "3000/tcp" "${API_PORT}/tcp")
    for port in "${ports[@]}"; do
        if ! ufw status | grep -q "${port%/*}"; then
            ufw allow "${port}" comment "IoT Logger" 2>&1 | tee -a "${LOG_FILE}"
        fi
    done
    
    log_success "Firewall configured"
}

deploy_containers() {
    log_info "[6/7] Starting Docker containers..."
    
    cd "${SCRIPT_DIR}"
    
    docker compose ps -q 2>/dev/null | grep -q . && docker compose down
    
    log_info "Building and starting containers..."
    docker compose up -d --build 2>&1 | tail -20 | tee -a "${LOG_FILE}"
    
    register_cleanup "docker compose down"
    
    # Wait for all containers to start
    log_info "Waiting for containers to start (max ${CONTAINER_START_TIMEOUT}s)..."
    local containers=("mosquitto" "influxdb" "telegraf" "api" "grafana")
    local elapsed=0
    
    while [ ${elapsed} -lt ${CONTAINER_START_TIMEOUT} ]; do
        local all_running=true
        
        for container in "${containers[@]}"; do
            if ! docker compose ps "${container}" 2>/dev/null | grep -q "Up"; then
                all_running=false
                break
            fi
        done
        
        if [ "${all_running}" = true ]; then
            log_success "All containers running"
            sleep 3  # Extra time for initialization
            return 0
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_error "Some containers failed to start"
    docker compose ps | tee -a "${LOG_FILE}"
    return 1
}

configure_mqtt_passwords() {
    log_info "[7/7] Configuring MQTT authentication..."
    
    log_info "Creating MQTT user: ${MQTTUSER}"
    if ! retry_with_backoff "docker compose exec -T mosquitto mosquitto_passwd -b -c /mosquitto/config/passwd '${MQTTUSER}' '${MQTTPASS}'" 3 2 10; then
        log_error "Failed to create MQTT user"
        docker compose logs mosquitto --tail=20 | tee -a "${LOG_FILE}"
        return 1
    fi
    
    log_info "Adding MQTT user: ${SENSOR_USER}"
    retry_with_backoff "docker compose exec -T mosquitto mosquitto_passwd -b /mosquitto/config/passwd '${SENSOR_USER}' '${SENSOR_PASS}'" 2 2 10 || log_warning "Sensor user not added"
    
    log_info "Restarting Mosquitto..."
    docker compose restart mosquitto 2>&1 | tee -a "${LOG_FILE}"
    
    sleep 5
    
    log_success "MQTT authentication configured"
}

main() {
    log_info "Starting deployment at $(date)"
    log_info "Log file: ${LOG_FILE}"
    echo ""
    
    validate_prerequisites
    validate_env_file
    check_dependencies
    setup_directories
    configure_firewall
    deploy_containers
    configure_mqtt_passwords
    
    echo ""
    log_success "==================================="
    log_success "✓ Deployment completed successfully!"
    log_success "==================================="
    echo ""
    
    cat <<EOF
Service URLs:
  - Grafana UI:  http://${PUBLIC_IP}:3000
  - InfluxDB UI: http://${PUBLIC_IP}:8086
  - API Docs:    http://${PUBLIC_IP}:${API_PORT}/docs
  - MQTT Broker: ${PUBLIC_IP}:1883

Credentials:
  - Grafana: ${GRAFANA_ADMIN_USER} / (see .env file)
  - InfluxDB: ${DOCKER_INFLUXDB_INIT_USERNAME} / (see .env file)
  - MQTT Telegraf: ${MQTTUSER}
  - MQTT Sensor: ${SENSOR_USER}

Management:
  - Status:      docker compose ps
  - Logs:        docker compose logs -f [service]
  - Restart:     docker compose restart [service]

Full log: ${LOG_FILE}
EOF
    
    echo ""
    log_info "Deployment finished at $(date)"
}

main "$@"
