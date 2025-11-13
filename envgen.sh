#!/bin/bash
# ==============================================================================
# Скрипт для генерации .env файла с безопасными учетными данными
# Использует .env.example как шаблон.
# ==============================================================================

set -euo pipefail

# --- КОНФИГУРАЦИЯ ---
readonly ENV_EXAMPLE=".env.example"
readonly ENV_FILE=".env"

# --- ЦВЕТА ДЛЯ ЛОГОВ ---
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # Без цвета

# --- ФУНКЦИИ ЛОГИРОВАНИЯ ---
log_info() { echo -e "${GREEN}[ИНФО]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $*"; }
log_error() { echo -e "${RED}[ОШИБКА]${NC} $*"; }

# --- ГЕНЕРАТОРЫ ДАННЫХ ---

# Генерирует безопасный пароль
generate_password() {
    openssl rand -base64 24
}

# Генерирует безопасный токен указанной длины
generate_token() {
    local length="${1:-64}"
    openssl rand -base64 96 | tr -d '=+/\n' | cut -c1-"${length}"
}

# Определяет публичный IP-адрес сервера
detect_public_ip() {
    local ip
    ip=$(curl -4 -s --max-time 3 ifconfig.me) || \
    ip=$(curl -4 -s --max-time 3 icanhazip.com) || \
    ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-"127.0.0.1"}"
}


# --- ОСНОВНАЯ ЛОГИКА ---
main() {
    log_info "Запуск генерации файла .env..."

    # 1. Проверка наличия .env.example
    if [ ! -f "${ENV_EXAMPLE}" ]; then
        log_error "Файл-шаблон '${ENV_EXAMPLE}' не найден. Поместите его в ту же директорию."
        exit 1
    fi

    # 2. Проверка, существует ли .env
    if [ -f "${ENV_FILE}" ]; then
        log_warn "Файл '${ENV_FILE}' уже существует."
        read -p "Вы уверены, что хотите перезаписать его? (y/N): " choice
        case "$choice" in
            y|Y ) log_info "Файл будет перезаписан.";;
            * ) log_info "Операция отменена."; exit 0;;
        esac
    fi

    # 3. Генерация новых значений
    log_info "Генерация безопасных учетных данных..."
    PUBLIC_IP=$(detect_public_ip)
    INFLUXDB_PASS=$(generate_password)
    # В .env.example DOCKER_INFLUXDB_INIT_ADMIN_TOKEN и INFLUXTOKEN используют один и тот же шаблон,
    # поэтому генерируем для них одно значение, как и предполагается.
    INFLUXDB_ADMIN_TOKEN=$(generate_token 64)
    TELEGRAF_PASS=$(generate_password)
    SENSOR_PASS=$(generate_password)
    API_TOKEN=$(generate_token 64)

    log_info "Публичный IP адрес определен как: ${PUBLIC_IP}"

    # 4. Копирование шаблона и замена значений
    log_info "Создание файла '${ENV_FILE}' на основе шаблона..."
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"

    # Используем sed для надежной замены значений по ключу
    sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=${PUBLIC_IP}|" "${ENV_FILE}"
    sed -i "s|^DOCKER_INFLUXDB_INIT_PASSWORD=.*|DOCKER_INFLUXDB_INIT_PASSWORD=${INFLUXDB_PASS}|" "${ENV_FILE}"
    sed -i "s|^DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=.*|DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}|" "${ENV_FILE}"
    sed -i "s|^MQTTPASS=.*|MQTTPASS=${TELEGRAF_PASS}|" "${ENV_FILE}"
    sed -i "s|^SENSORPASS=.*|SENSORPASS=${SENSOR_PASS}|" "${ENV_FILE}"
    sed -i "s|^INFLUXTOKEN=.*|INFLUXTOKEN=${INFLUXDB_ADMIN_TOKEN}|" "${ENV_FILE}"
    sed -i "s|^API_TOKEN=.*|API_TOKEN=${API_TOKEN}|" "${ENV_FILE}"

    # 5. Установка прав доступа
    chmod 600 "${ENV_FILE}"

    log_info "--------------------------------------------------"
    log_info "Файл '${ENV_FILE}' успешно создан и защищен."
    log_info "Сохраните эти данные в безопасном месте."
    log_info "--------------------------------------------------"
    
    # Показать результат без комментариев
    grep -v '^#' "${ENV_FILE}"
}

# --- ЗАПУСК СКРИПТА ---
main

